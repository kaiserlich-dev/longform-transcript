require "digest"
require "fileutils"
require "ipaddr"
require "net/http"
require "open3"
require "resolv"
require "tmpdir"
require "uri"

module LongformTranscript
  class Run < ApplicationRecord
  SCHEMA_VERSION = "diarized-segments-v1"
  MAX_REDIRECTS = 3
  STATUSES = %w[prepared processing completed failed].freeze
  REVIEW_STATUSES = %w[pending_review approved rejected].freeze
  RETRYABLE_ERRORS = [
    Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNRESET, Errno::ETIMEDOUT,
    RubyLLM::RateLimitError, RubyLLM::ServerError, RubyLLM::ServiceUnavailableError, RubyLLM::OverloadedError
  ].freeze
  SOURCE_MATCH_WORDS = 8
  SOURCE_MATCH_WINDOW = 30
  SOURCE_RETRYABLE_ERRORS = [ Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNRESET, Errno::ETIMEDOUT ].freeze
  BLOCKED_NETWORKS = %w[
    0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12
    192.0.0.0/24 192.0.2.0/24 192.168.0.0/16 198.18.0.0/15 198.51.100.0/24 203.0.113.0/24
    224.0.0.0/4 240.0.0.0/4 ::/128 ::1/128 fc00::/7 fe80::/10 ff00::/8 2001:db8::/32
  ].map { |network| IPAddr.new(network) }.freeze

  class ExternalFailure < StandardError
    attr_reader :code

    def initialize(code, retryable:)
      @code = code
      @retryable = retryable
      super(code)
    end

    def retryable?
      @retryable
    end
  end

  class InvalidTranscription < ArgumentError
    attr_reader :reason, :item_index

    def initialize(reason, item_index)
      @reason = reason
      @item_index = item_index
      super("#{reason} at word #{item_index}")
    end
  end

  belongs_to :transcribable, polymorphic: true
  has_many :chunks, -> { ordered }, dependent: :restrict_with_exception
  has_many :turns, -> { order(:position) }, dependent: :restrict_with_exception
  has_many :speaker_mappings, dependent: :restrict_with_exception

  validates :source_audio_url, :source_audio_identity, :model, :prompt_version, :schema_version, :status, :review_status,
    presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :review_status, inclusion: { in: REVIEW_STATUSES }
  validates :source_audio_identity,
    uniqueness: { scope: %i[transcribable_type transcribable_id model prompt_version schema_version] }
  validate :published_with_complete_speaker_mappings, if: :published_at?

  scope :published, -> { where.not(published_at: nil) }

  def playback_start_ms_for(source_text)
    source_words = normalized_text(source_text).split.first(SOURCE_MATCH_WINDOW)
    return if source_words.length < SOURCE_MATCH_WORDS

    timed_words = turns.flat_map do |turn|
      words = normalized_text(turn.text).split
      words.map.with_index do |word, index|
        [ word, turn.start_ms + ((turn.end_ms - turn.start_ms) * index.fdiv(words.length)).round ]
      end
    end
    transcript_words = timed_words.map(&:first)

    source_words.each_cons(SOURCE_MATCH_WORDS) do |phrase|
      matches = transcript_words.each_index.select { |index| transcript_words.slice(index, SOURCE_MATCH_WORDS) == phrase }
      return timed_words.fetch(matches.sole).last if matches.one?
    end

    nil
  end

  def self.prepare_for!(transcribable, source_audio_url:, model:, profile:)
    profile = profile.to_h.deep_symbolize_keys
    raise ArgumentError, "Profile requires a version and interface" unless profile.values_at(:version, :interface).all?(&:present?)

    url = canonical_audio_url(source_audio_url)
    identity_uri = URI.parse(url)
    identity_uri.query = nil
    identity = Digest::SHA256.hexdigest(identity_uri.to_s)
    identity_attributes = {
      transcribable: transcribable, source_audio_identity: identity, model: model,
      prompt_version: profile.fetch(:version), schema_version: SCHEMA_VERSION
    }
    run = find_by(identity_attributes)
    unless run
      begin
        run = create!(identity_attributes.merge(source_audio_url: url, profile: profile))
      rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => error
        run = find_by(identity_attributes)
        raise error unless run
      end
    end
    run.update!(source_audio_url: url, profile: profile) if run.status != "completed" &&
      (run.source_audio_url != url || run.profile.deep_symbolize_keys != profile)
    run
  end

  def self.canonical_audio_url(value)
    uri = URI.parse(value)
    raise ArgumentError, "Audio URL must use HTTPS" unless uri.is_a?(URI::HTTPS) && uri.host.present?

    uri.fragment = nil
    uri.normalize.to_s
  rescue URI::InvalidURIError
    raise ArgumentError, "Audio URL is invalid"
  end

  def process_next_chunk!
    return if status == "completed"

    return unless ensure_audio!
    chunk = claim_next_chunk!
    return finalize_if_complete! unless chunk

    process_chunk!(chunk)
    finalize_if_complete!
  end

  def work_remaining?
    reload
    chunk = chunks.where.not(status: "completed").ordered.first
    status != "completed" && chunk.present? && (chunk.status == "pending" || chunk.retry_available?)
  end

  def retry_invalid_output!
    with_lock do
      failed_chunks = chunks.where(
        status: "failed", failure_code: "invalid_structured_output", retryable: true
      )
      unless status == "failed" && failure_code == "invalid_structured_output" && failed_chunks.exists?
        raise ArgumentError, "Run has no retryable invalid output"
      end

      failed_chunks.update_all(
        status: "pending", retry_count: 0, retryable: true, failure_code: nil, claimed_at: nil,
        started_at: nil, failed_at: nil, updated_at: Time.current
      )
      update!(status: "processing", failure_code: nil, failed_at: nil)
    end
  end

  def approve!
    with_lock do
      raise ActiveRecord::RecordInvalid, self unless status == "completed"

      update!(review_status: "approved", reviewed_at: Time.current)
    end
  end

  def reject!
    update!(review_status: "rejected", reviewed_at: Time.current)
  end

  def publish!(speaker_names)
    with_lock do
      raise ActiveRecord::RecordInvalid, self unless status == "completed"

      speaker_ids = turns.distinct.reorder(:speaker_id).pluck(:speaker_id)
      normalized_names = speaker_names.to_h.transform_keys(&:to_s).transform_values { |name| name.to_s.squish }
      raise ArgumentError, "Speaker mappings must cover every speaker exactly" unless normalized_names.keys.sort == speaker_ids
      raise ArgumentError, "Speaker names cannot be blank" if normalized_names.values.any?(&:blank?)

      transaction do
        self.class.published.where(transcribable: transcribable).where.not(id: id)
          .update_all(published_at: nil, updated_at: Time.current)
        LongformTranscript::SpeakerMapping.where(run_id: id).delete_all
        now = Time.current
        normalized_names.each do |speaker_id, display_name|
          speaker_mappings.create!(
            speaker_id: speaker_id, display_name: display_name, reviewed_at: now
          )
        end
        update!(review_status: "approved", reviewed_at: now, published_at: now)
      end
    end
    LongformTranscript.publication_callback&.call(self)
    self
  end

  def release_stale_chunks!(before: LongformTranscript.stale_after.ago)
    with_lock do
      chunks.where(status: "processing").where(claimed_at: ...before).update_all(
        status: "failed", retryable: true, failure_code: "stale_claim", failed_at: Time.current,
        claimed_at: nil, updated_at: Time.current
      )
    end
  end

  def record_source_failure!(error)
    update!(status: "failed", failed_at: Time.current, failure_code: error.code)
  end

  def audio_path
    work_directory.join("source.mp3")
  end

  private

  def published_with_complete_speaker_mappings
    expected = turns.distinct.pluck(:speaker_id).sort
    actual = speaker_mappings.where.not(display_name: "").distinct.pluck(:speaker_id).sort
    errors.add(:published_at, "requires a reviewed name for every speaker") if expected.empty? || actual != expected
  end

  def ensure_audio!
    return true if reusable_audio?

    claimed = with_lock do
      next false if audio_claimed_at && audio_claimed_at > LongformTranscript.stale_after.ago

      update!(audio_claimed_at: Time.current, status: "processing", started_at: started_at || Time.current)
      true
    end
    return false unless claimed

    FileUtils.mkdir_p(work_directory)
    temporary_path = work_directory.join("source.download")
    instrument_phase("audio_download") { download_audio!(temporary_path) }
    digest = instrument_phase("audio_checksum") { Digest::SHA256.file(temporary_path).hexdigest }
    duration_ms = instrument_phase("audio_probe") { probe_duration_ms(temporary_path) }

    with_lock do
      if source_audio_sha256.present? && source_audio_sha256 != digest
        raise ExternalFailure.new("source_audio_changed", retryable: false)
      end

      update!(source_audio_sha256: digest, audio_duration_ms: duration_ms, status: "processing", audio_claimed_at: nil,
        started_at: started_at || Time.current, failed_at: nil, failure_code: nil)
      prepare_chunks!(digest, duration_ms)
    end
    FileUtils.mv(temporary_path, audio_path)
    true
  rescue ExternalFailure
    update!(audio_claimed_at: nil)
    raise
  ensure
    FileUtils.rm_f(temporary_path) if temporary_path
  end

  def reusable_audio?
    return false unless audio_path.file? && source_audio_sha256.present? && audio_duration_ms.present?

    Digest::SHA256.file(audio_path).hexdigest == source_audio_sha256
  end

  def prepare_chunks!(digest, duration_ms)
    return if chunks.exists?

    chunk_duration_ms = LongformTranscript.chunk_duration.in_milliseconds
    chunk_overlap_ms = LongformTranscript.chunk_overlap.in_milliseconds
    count = (duration_ms.to_f / chunk_duration_ms).ceil
    count.times do |number|
      core_start = number * chunk_duration_ms
      core_end = [ (number + 1) * chunk_duration_ms, duration_ms ].min
      chunks.create!(
        number: number, start_ms: [ core_start - chunk_overlap_ms, 0 ].max,
        end_ms: [ core_end + chunk_overlap_ms, duration_ms ].min, source_digest: digest
      )
    end
  end

  def claim_next_chunk!
    with_lock do
      stale_before = LongformTranscript.stale_after.ago
      chunks.where(status: "processing").where(claimed_at: ...stale_before).update_all(
        status: "failed", retryable: true, failure_code: "stale_claim", failed_at: Time.current,
        claimed_at: nil, updated_at: Time.current
      )
      return if chunks.where(status: "processing").exists?

      chunk = chunks.where.not(status: "completed").ordered.first
      return unless chunk

      unless chunk.status == "pending" || chunk.retry_available?
        update!(status: "failed", failed_at: Time.current, failure_code: chunk.failure_code)
        return
      end

      now = Time.current
      chunk.update!(status: "processing", retry_count: chunk.retry_count + 1, claimed_at: now,
        started_at: chunk.started_at || now, failed_at: nil, failure_code: nil)
      chunk
    end
  end

  def process_chunk!(chunk)
    Dir.mktmpdir("longform-transcript-chunk") do |directory|
      clip_path = Pathname(directory).join("chunk-#{chunk.number}.mp3")
      instrument_phase("clip", chunk_number: chunk.number) { create_clip!(chunk, clip_path) }
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      profile = self.profile.deep_symbolize_keys
      response, turns, words = instrument_phase("provider", chunk_number: chunk.number) do
        transcript_chunk(clip_path, chunk, profile)
      end
      latency_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1_000).round
      stable_turns = stabilize_speakers(turns, chunk, words)
      speaker_mapping = turns.zip(stable_turns).to_h { |local, stable| [ local.fetch("speaker_id"), stable.fetch("speaker_id") ] }
      words.each { |word| word["speaker_id"] = speaker_mapping.fetch(word.fetch("speaker_id")) }
      complete_chunk!(chunk, stable_turns, words, response, latency_ms)
    end
  rescue ExternalFailure => error
    fail_chunk!(chunk, error.code, retryable: error.retryable?)
  rescue *RETRYABLE_ERRORS
    fail_chunk!(chunk, "provider_transient", retryable: true)
  rescue JSON::ParserError, KeyError, TypeError, ArgumentError
    fail_chunk!(chunk, "invalid_structured_output", retryable: true)
  rescue RubyLLM::Error
    fail_chunk!(chunk, "provider_permanent", retryable: false)
  end

  def create_clip!(chunk, path)
    duration = (chunk.end_ms - chunk.start_ms) / 1000.0
    _, error, status = Open3.capture3(
      "ffmpeg", "-hide_banner", "-loglevel", "error", "-ss", format("%.3f", chunk.start_ms / 1000.0),
      "-i", audio_path.to_s, "-t", format("%.3f", duration), "-map_metadata", "-1", "-ac", "1", "-ar", "16000",
      "-b:a", "48k", path.to_s
    )
    raise ExternalFailure.new("ffmpeg_failed", retryable: false) unless status.success? && path.file? && path.size.positive?
  ensure
    Rails.logger.warn("Speaker transcript ffmpeg failed for run #{id}") if defined?(status) && !status.success? && error.present?
  end

  def transcript_chunk(clip_path, chunk, profile)
    provider = profile.fetch(:provider, :openrouter).to_sym
    if profile.fetch(:interface).to_sym == :multimodal_chat
      response = RubyLLM.chat(model: model, provider: provider)
        .with_temperature(0).with_schema(LongformTranscript::TranscriptSchema)
        .ask(multimodal_transcription_prompt(chunk), with: clip_path.to_s)
      [ response, validated_multimodal_transcription(response, chunk), [] ]
    else
      begin
        options = {
          model: model,
          provider: provider,
          format: "verbose_json",
          timestamps: [ :segment, :word ],
          provider_options: { provider: profile.fetch(:provider_options, {}) }
        }
        options[:language] = profile.fetch(:language) if profile[:language].present?
        response = RubyLLM.transcribe(clip_path.to_s, **options)
        turns, words = validated_transcription(response, chunk)
        [ response, turns, words ]
      rescue JSON::ParserError, KeyError, TypeError, ArgumentError => error
        log_invalid_transcription_shape(response, error)
        raise
      end
    end
  end

  def multimodal_transcription_prompt(chunk)
    return profile.fetch("instructions") if profile["instructions"].present?

    <<~PROMPT
      Transcribe this recording verbatim and completely in its original language.
      Separate every speaker change. Use only neutral speaker IDs such as speaker_1 and speaker_2;
      do not invent names. start_ms and end_ms are precise milliseconds relative to the beginning of this
      #{chunk.end_ms - chunk.start_ms} millisecond audio excerpt. All timestamps must be monotonic and within
      the excerpt, and end_ms must be greater than start_ms. Return only the structured result.
    PROMPT
  end

  def validated_multimodal_transcription(response, chunk)
    payload = response.content
    payload = response.parsed if !payload.is_a?(Hash) && response.respond_to?(:parsed)
    payload = JSON.parse(payload) unless payload.is_a?(Hash)
    turns = payload.deep_stringify_keys.fetch("turns")
    raise TypeError unless turns.is_a?(Array) && turns.any?

    speakers = {}
    duration = chunk.end_ms - chunk.start_ms
    previous_start = -1
    turns.map do |item|
      item = item.deep_stringify_keys
      raw_speaker = item.fetch("speaker_id").to_s
      speaker = speakers[raw_speaker] ||= "speaker_#{speakers.length + 1}"
      text = item.fetch("text").to_s.squish
      start_ms = Integer(item.fetch("start_ms"))
      end_ms = Integer(item.fetch("end_ms"))
      unless raw_speaker.present? && text.present? && start_ms >= previous_start && start_ms >= 0 &&
          end_ms > start_ms && end_ms <= duration + 1_000
        raise ArgumentError
      end

      previous_start = start_ms
      { "speaker_id" => speaker, "start_ms" => start_ms + chunk.start_ms,
        "end_ms" => [ end_ms, duration ].min + chunk.start_ms, "text" => text }
    end
  end

  def validated_transcription(response, chunk)
    segments = response.segments
    words = response.words
    raise TypeError unless words.is_a?(Array) && words.any?

    duration = chunk.end_ms - chunk.start_ms
    timestamped_words = words.map.with_index do |item, index|
      item = item.deep_stringify_keys
      raw_speaker = item.fetch("speaker").to_s
      text = item.fetch("word") { item.fetch("text") }.to_s.squish
      raise InvalidTranscription.new("missing_speaker", index) if raw_speaker.blank?
      raise InvalidTranscription.new("blank_text", index) if text.blank?

      begin
        start_ms = (Float(item.fetch("start")) * 1_000).round
        end_ms = (Float(item.fetch("end")) * 1_000).round
      rescue KeyError, TypeError, ArgumentError
        raise InvalidTranscription.new("invalid_numeric_timestamp", index)
      end
      raise InvalidTranscription.new("negative_start", index) if start_ms.negative?
      raise InvalidTranscription.new("nonpositive_duration", index) if end_ms <= start_ms
      raise InvalidTranscription.new("out_of_range", index) if end_ms > duration + 1_000

      { raw_speaker: raw_speaker, text: text, start_ms: start_ms, end_ms: end_ms, item_index: index }
    end.sort_by { |word| [ word.fetch(:start_ms), word.fetch(:item_index) ] }

    speakers = {}
    normalized_words = timestamped_words.map do |word|
      local_speaker = speakers[word.fetch(:raw_speaker)] ||= "speaker_#{speakers.length + 1}"
      { "speaker_id" => local_speaker, "start_ms" => word.fetch(:start_ms) + chunk.start_ms,
        "end_ms" => [ word.fetch(:end_ms), duration ].min + chunk.start_ms, "text" => word.fetch(:text) }
    end

    turns = normalized_segment_turns(segments, speakers, chunk) || turns_from_words(normalized_words)
    [ turns, normalized_words ]
  end

  def normalized_segment_turns(segments, speakers, chunk)
    return unless segments.is_a?(Array) && segments.any?
    return unless segments.all? { |item| item.to_h.stringify_keys["speaker"].present? }

    duration = chunk.end_ms - chunk.start_ms
    previous_start = -1
    segments.map do |item|
      item = item.deep_stringify_keys
      raw_speaker = item.fetch("speaker").to_s
      text = item.fetch("text").to_s.squish
      start_ms = (Float(item.fetch("start")) * 1_000).round
      end_ms = (Float(item.fetch("end")) * 1_000).round
      unless speakers.key?(raw_speaker) && text.present? && start_ms >= previous_start && start_ms >= 0 &&
          end_ms > start_ms && end_ms <= duration + 1_000
        return
      end

      previous_start = start_ms
      { "speaker_id" => speakers.fetch(raw_speaker), "start_ms" => start_ms + chunk.start_ms,
        "end_ms" => [ end_ms, duration ].min + chunk.start_ms, "text" => text }
    end
  rescue KeyError, TypeError, ArgumentError
    nil
  end

  def log_invalid_transcription_shape(response, error)
    segments = response.segments if response.respond_to?(:segments)
    words = response.words if response.respond_to?(:words)
    Rails.logger.warn({
      event: "speaker_transcript_invalid_output", run_id: id, error_class: error.class.name,
      reason: error.respond_to?(:reason) ? error.reason : nil,
      item_index: error.respond_to?(:item_index) ? error.item_index : nil,
      segments_class: segments.class.name, segments_count: segments.respond_to?(:size) ? segments.size : nil,
      words_class: words.class.name, words_count: words.respond_to?(:size) ? words.size : nil
    }.compact.to_json)
  end

  def turns_from_words(words)
    words.chunk_while { |left, right| left.fetch("speaker_id") == right.fetch("speaker_id") }.map do |passage|
      {
        "speaker_id" => passage.first.fetch("speaker_id"), "start_ms" => passage.first.fetch("start_ms"),
        "end_ms" => passage.last.fetch("end_ms"), "text" => transcript_words(passage)
      }
    end
  end

  def stabilize_speakers(turns, chunk, words = [])
    previous_output = chunks.where(status: "completed", number: chunk.number - 1).pick(:output) || {}
    previous = previous_output.fetch("turns", [])
    mapping = overlapping_word_speaker_mapping(previous_output.fetch("words", []), words)
    used = mapping.values
    turns.each do |turn|
      next if mapping.key?(turn.fetch("speaker_id"))

      match = previous.reject { |candidate| used.include?(candidate.fetch("speaker_id")) }.max_by do |candidate|
        transcript_overlap_score(turn.fetch("text"), candidate.fetch("text"))
      end
      next unless match && transcript_overlap_score(turn.fetch("text"), match.fetch("text")).positive?

      mapping[turn.fetch("speaker_id")] ||= match.fetch("speaker_id")
      used << match.fetch("speaker_id")
    end

    known_speakers = chunks.where(status: "completed", number: ...chunk.number).ordered.pluck(:output)
      .flat_map { |output| output.fetch("turns", []).map { |turn| turn.fetch("speaker_id") } }
      .uniq.sort_by { |speaker| speaker[/\d+\z/].to_i }
    available_speakers = known_speakers - used
    next_number = known_speakers.filter_map { |speaker| speaker[/\d+\z/].to_i }.max.to_i + 1
    turns.map do |turn|
      local = turn.fetch("speaker_id")
      mapping[local] ||= begin
        speaker = available_speakers.shift
        unless speaker
          speaker = "speaker_#{next_number}"
          next_number += 1
        end
        speaker
      end
      turn.merge("speaker_id" => mapping.fetch(local))
    end
  end

  def overlapping_word_speaker_mapping(previous_words, words)
    candidates = previous_words.group_by { |word| word.fetch("speaker_id") }
    mapping = {}
    used = []
    words.group_by { |word| word.fetch("speaker_id") }.each do |local_speaker, local_words|
      votes = candidates.to_h do |stable_speaker, stable_words|
        matches = local_words.count do |word|
          token = normalized_text(word.fetch("text"))
          token.present? && stable_words.any? do |candidate|
            normalized_text(candidate.fetch("text")) == token &&
              (candidate.fetch("start_ms") - word.fetch("start_ms")).abs <= 250
          end
        end
        [ stable_speaker, matches ]
      end
      stable_speaker, matches = votes.reject { |speaker, _| used.include?(speaker) }.max_by(&:last)
      next unless matches.to_i >= 2

      mapping[local_speaker] = stable_speaker
      used << stable_speaker
    end
    mapping
  end

  def complete_chunk!(chunk, turns, words, response, latency_ms)
    input_tokens = response.tokens.input.to_i
    output_tokens = response.tokens.output.to_i
    cost = response_cost(response)
    chunk.with_lock do
      return if chunk.status == "completed"

      chunk.update!(
        status: "completed", output: { "turns" => turns, "words" => words }, model: response_model(response),
        input_tokens: input_tokens, output_tokens: output_tokens, reported_cost_usd: cost,
        latency_ms: latency_ms, completed_at: Time.current, claimed_at: nil, failure_code: nil
      )
    end
  end

  def response_cost(response)
    response.tokens.reported_cost.to_d
  end

  def response_model(response)
    returned_model = response.respond_to?(:model) ? response.model : response.model_id
    returned_model.presence || model
  end

  def fail_chunk!(chunk, code, retryable:)
    chunk.with_lock do
      chunk.update!(status: "failed", retryable: retryable, failure_code: code, failed_at: Time.current, claimed_at: nil)
    end
    terminal = with_lock do
      next false if chunk.retry_available?

      update!(status: "failed", failed_at: Time.current, failure_code: code)
      true
    end
    FileUtils.rm_rf(work_directory) if terminal
  end

  def finalize_if_complete!
    with_lock do
      return unless chunks.exists? && chunks.where.not(status: "completed").none?

      assembled = assembled_turn_attributes
      LongformTranscript::Turn.where(run_id: id).delete_all
      assembled.each_with_index do |attributes, position|
        turns.create!(attributes.merge(position: position))
      end
      metrics = chunks.pick(
        Arel.sql("COALESCE(SUM(input_tokens), 0)"), Arel.sql("COALESCE(SUM(output_tokens), 0)"),
        Arel.sql("COALESCE(SUM(reported_cost_usd), 0)"), Arel.sql("COALESCE(SUM(latency_ms), 0)")
      )
      update!(status: "completed", completed_at: Time.current, failed_at: nil, failure_code: nil,
        input_tokens: metrics[0], output_tokens: metrics[1], reported_cost_usd: metrics[2], total_latency_ms: metrics[3])
    end
    FileUtils.rm_rf(work_directory)
    true
  end

  def assembled_turn_attributes
    seen = {}
    turns = chunks.ordered.flat_map do |chunk|
      timestamped_turns_for(chunk).filter_map do |turn|
        midpoint = (turn.fetch("start_ms") + turn.fetch("end_ms")) / 2
        next unless midpoint >= chunk.core_start_ms && midpoint < chunk.core_end_ms

        duplicate_key = [ turn.fetch("speaker_id"), normalized_text(turn.fetch("text")) ]
        next if seen[duplicate_key]

        seen[duplicate_key] = true
        {
          chunk: chunk, start_ms: turn.fetch("start_ms"), end_ms: turn.fetch("end_ms"),
          speaker_id: turn.fetch("speaker_id"), text: turn.fetch("text")
        }
      end
    end.sort_by { |turn| [ turn.fetch(:start_ms), turn.fetch(:end_ms), turn.fetch(:speaker_id) ] }
    trim_boundary_overlaps(turns)
  end

  def timestamped_turns_for(chunk)
    words = chunk.output.fetch("words", [])
    return chunk.output.fetch("turns") if words.empty?

    words.filter do |word|
      midpoint = (word.fetch("start_ms") + word.fetch("end_ms")) / 2
      midpoint >= chunk.core_start_ms && midpoint < chunk.core_end_ms
    end.chunk_while do |left, right|
      left.fetch("speaker_id") == right.fetch("speaker_id")
    end.map do |passage|
      {
        "speaker_id" => passage.first.fetch("speaker_id"),
        "start_ms" => passage.first.fetch("start_ms"),
        "end_ms" => passage.last.fetch("end_ms"),
        "text" => transcript_words(passage)
      }
    end
  end

  def transcript_words(words)
    words.pluck("text").join(" ").gsub(/\s+([,.;:!?])/, "\\1")
  end

  def trim_boundary_overlaps(turns)
    turns.each_with_object([]) do |turn, result|
      previous = result.last(6).reverse.find do |candidate|
        candidate.fetch(:speaker_id) == turn.fetch(:speaker_id) &&
          candidate.fetch(:chunk).id != turn.fetch(:chunk).id
      end
      if previous
        text = trim_leading_overlap(previous.fetch(:text), turn.fetch(:text))
        next if text.blank?

        turn = turn.merge(text: text)
      end
      result << turn
    end
  end

  def trim_leading_overlap(previous_text, current_text)
    previous_tokens = word_tokens(previous_text).last(80)
    current_tokens = word_tokens(current_text).first(80)
    pairs = longest_common_subsequence(previous_tokens.map(&:first), current_tokens.map(&:first))
    return current_text if pairs.length < 8 || pairs.first.last > 3

    chain = pairs.each_with_object([]) do |pair, matches|
      break matches if matches.any? && (pair.first - matches.last.first > 4 || pair.last - matches.last.last > 4)

      matches << pair
    end
    covered_words = chain.last.last + 1
    return current_text if chain.length < 8 || chain.length.fdiv(covered_words) < 0.6

    matched_end = current_tokens.fetch(chain.last.last).last
    sentence_tail = current_text[matched_end, 160]
    connector = sentence_tail&.match(/\A.{0,100}?,\s+(aber|sondern|doch)\b/i)
    if connector
      remainder = current_text[(matched_end + connector.begin(1))..].to_s.squish
      return remainder.sub(/\A[[:lower:]]/) { |letter| letter.upcase }
    end

    sentence_end = sentence_tail&.match(/\A[^.!?]*[.!?](?:\s|\z)/)&.end(0)
    current_text[(matched_end + sentence_end.to_i)..].to_s.sub(/\A[^[:alnum:]]+/, "").squish
  end

  def word_tokens(text)
    text.to_enum(:scan, /[[:alnum:]]+/).map do
      [ Regexp.last_match[0].downcase, Regexp.last_match.end(0) ]
    end
  end

  def longest_common_subsequence(left, right)
    lengths = Array.new(left.length + 1) { Array.new(right.length + 1, 0) }
    left.each_index do |left_index|
      right.each_index do |right_index|
        lengths[left_index + 1][right_index + 1] = if left[left_index] == right[right_index]
          lengths[left_index][right_index] + 1
        else
          [ lengths[left_index][right_index + 1], lengths[left_index + 1][right_index] ].max
        end
      end
    end

    pairs = []
    left_index = left.length
    right_index = right.length
    while left_index.positive? && right_index.positive?
      if left[left_index - 1] == right[right_index - 1]
        pairs.unshift([ left_index - 1, right_index - 1 ])
        left_index -= 1
        right_index -= 1
      elsif lengths[left_index - 1][right_index] >= lengths[left_index][right_index - 1]
        left_index -= 1
      else
        right_index -= 1
      end
    end
    pairs
  end

  def normalized_text(text)
    text.to_s.downcase.gsub(/[^[:alnum:]]+/, " ").squish
  end

  def transcript_overlap_score(left, right)
    left_words = normalized_text(left).split.first(80)
    right_words = normalized_text(right).split.last(80)
    shorter_length = [ left_words.length, right_words.length ].min
    return 0 if shorter_length < 4

    score = longest_common_subsequence(left_words, right_words).length
    exact = left_words == right_words
    exact || (score >= 6 && score.fdiv(shorter_length) >= 0.6) ? score : 0
  end

  def work_directory
    root = LongformTranscript.storage_root.respond_to?(:call) ? LongformTranscript.storage_root.call : LongformTranscript.storage_root
    Pathname(root).join(id.to_s)
  end

  def instrument_phase(phase, chunk_number: nil)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    outcome = "failed"
    result = yield
    outcome = "completed"
    result
  ensure
    duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1_000).round if started
    Rails.logger.info({ event: "speaker_transcript_phase", run_id: id, chunk_number: chunk_number,
      phase: phase, outcome: outcome, duration_ms: duration_ms }.compact.to_json)
  end

  def download_audio!(destination, url = source_audio_url, redirects = 0)
    raise ExternalFailure.new("too_many_redirects", retryable: false) if redirects > MAX_REDIRECTS

    uri = URI.parse(url)
    raise ExternalFailure.new("unsafe_audio_url", retryable: false) unless uri.is_a?(URI::HTTPS)
    addresses = Resolv.getaddresses(uri.host)
    if addresses.empty? || addresses.any? { |address| blocked_address?(address) }
      raise ExternalFailure.new("unsafe_audio_url", retryable: false)
    end

    http = Net::HTTP.new(uri.host, uri.port)
    http.ipaddr = addresses.first
    http.use_ssl = true
    http.open_timeout = 10
    http.read_timeout = 30
    http.start do |connection|
      request = Net::HTTP::Get.new(uri.request_uri, { "User-Agent" => "LongformTranscript/1.0" })
      connection.request(request) do |response|
        if response.is_a?(Net::HTTPRedirection)
          location = response["location"]
          raise ExternalFailure.new("invalid_redirect", retryable: false) if location.blank?

          redirected = URI.join(url, location).to_s
          return download_audio!(destination, redirected, redirects + 1)
        end
        unless response.is_a?(Net::HTTPSuccess)
          retryable = response.is_a?(Net::HTTPServerError) || [ "408", "429" ].include?(response.code)
          raise ExternalFailure.new("audio_http_error", retryable: retryable)
        end
        if response.content_length && response.content_length > LongformTranscript.download_limit
          raise ExternalFailure.new("audio_too_large", retryable: false)
        end

        bytes = 0
        File.open(destination, "wb") do |file|
          response.read_body do |data|
            bytes += data.bytesize
            raise ExternalFailure.new("audio_too_large", retryable: false) if bytes > LongformTranscript.download_limit
            file.write(data)
          end
        end
      end
    end
  rescue URI::InvalidURIError
    raise ExternalFailure.new("unsafe_audio_url", retryable: false)
  rescue *SOURCE_RETRYABLE_ERRORS
    raise ExternalFailure.new("audio_network_error", retryable: true)
  end

  def blocked_address?(address)
    ip = IPAddr.new(address)
    BLOCKED_NETWORKS.any? { |network| network.include?(ip) }
  rescue IPAddr::InvalidAddressError
    true
  end

  def probe_duration_ms(path)
    output, _, status = Open3.capture3(
      "ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", path.to_s
    )
    duration_ms = (Float(output.strip) * 1000).round
    raise ExternalFailure.new("invalid_audio", retryable: false) unless status.success? && duration_ms.positive?

    duration_ms
  rescue ArgumentError
    raise ExternalFailure.new("invalid_audio", retryable: false)
  end
  end
end
