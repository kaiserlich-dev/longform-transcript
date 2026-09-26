require "digest"
require "fileutils"
require "tmpdir"
require "uri"

module LongformTranscript
  class Run < ApplicationRecord
    SCHEMA_VERSION = "diarized-segments-v1"
    MAX_REDIRECTS = Audio::MAX_REDIRECTS
    STATUSES = %w[prepared processing completed failed].freeze
    REVIEW_STATUSES = %w[pending_review approved rejected].freeze
    RETRYABLE_ERRORS = [
      Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNRESET, Errno::ETIMEDOUT,
      RubyLLM::RateLimitError, RubyLLM::ServerError, RubyLLM::ServiceUnavailableError, RubyLLM::OverloadedError
    ].freeze
    SOURCE_RETRYABLE_ERRORS = Audio::RETRYABLE_ERRORS
    BLOCKED_NETWORKS = Audio::BLOCKED_NETWORKS
    SOURCE_MATCH_WORDS = 8
    SOURCE_MATCH_WINDOW = 30

    class ExternalFailure < StandardError
      attr_reader :code

      def initialize(code, retryable:)
        @code = code
        @retryable = retryable
        super(code)
      end

      def retryable? = @retryable
    end

    InvalidTranscription = Transcriber::InvalidOutput

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

    def self.prepare_for!(transcribable, source_audio_url:, model:, profile:)
      profile = profile.to_h.deep_symbolize_keys
      raise ArgumentError, "Profile requires a version and interface" unless profile.values_at(:version, :interface).all?(&:present?)

      url = Audio.canonical_url(source_audio_url)
      identity_uri = URI.parse(url)
      identity_uri.query = nil
      identity_attributes = {
        transcribable: transcribable, source_audio_identity: Digest::SHA256.hexdigest(identity_uri.to_s), model: model,
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

    def self.canonical_audio_url(value) = Audio.canonical_url(value)

    def playback_start_ms_for(source_text)
      source_words = Text.normalize(source_text).split.first(SOURCE_MATCH_WINDOW)
      return if source_words.length < SOURCE_MATCH_WORDS

      timed_words = turns.flat_map do |turn|
        words = Text.normalize(turn.text).split
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

    def process_next_chunk! = process_next_batch!(limit: 1)

    def process_next_batch!(limit: LongformTranscript.chunk_concurrency)
      raise ArgumentError, "Chunk concurrency must be a positive integer" unless limit.is_a?(Integer) && limit.positive?
      return if reload.status == "completed"
      return finalize_if_complete! if chunks.exists? && chunks.where.not(status: "completed").none?
      return unless ensure_audio!

      process_chunks!(claim_next_chunks!(limit))
      finalize_if_complete!
    end

    def work_remaining?
      reload
      return false if status.in?(%w[completed failed]) || chunks.where(status: "processing").exists?

      chunk = chunks.where.not(status: "completed").ordered.first
      chunk.present? && (chunk.status == "pending" || chunk.retry_available?)
    end

    def retry_invalid_output!
      with_lock do
        failed_chunks = chunks.where(status: "failed", failure_code: "invalid_structured_output", retryable: true)
        unless status == "failed" && failure_code == "invalid_structured_output" && failed_chunks.exists?
          raise ArgumentError, "Run has no retryable invalid output"
        end
        failed_chunks.update_all(status: "pending", retry_count: 0, retryable: true, failure_code: nil,
          claimed_at: nil, started_at: nil, failed_at: nil, updated_at: Time.current)
        update!(status: "processing", failure_code: nil, failed_at: nil)
      end
    end

    def approve!
      with_lock do
        raise ActiveRecord::RecordInvalid, self unless status == "completed"
        update!(review_status: "approved", reviewed_at: Time.current)
      end
    end

    def reject! = update!(review_status: "rejected", reviewed_at: Time.current)

    def publish!(speaker_names)
      with_lock do
        raise ActiveRecord::RecordInvalid, self unless status == "completed"

        speaker_ids = turns.distinct.reorder(:speaker_id).pluck(:speaker_id)
        names = speaker_names.to_h.transform_keys(&:to_s).transform_values { |name| name.to_s.squish }
        raise ArgumentError, "Speaker mappings must cover every speaker exactly" unless names.keys.sort == speaker_ids
        raise ArgumentError, "Speaker names cannot be blank" if names.values.any?(&:blank?)

        transaction do
          self.class.published.where(transcribable: transcribable).where.not(id: id)
            .update_all(published_at: nil, updated_at: Time.current)
          LongformTranscript::SpeakerMapping.where(run_id: id).delete_all
          now = Time.current
          names.each { |speaker_id, display_name| speaker_mappings.create!(speaker_id: speaker_id,
            display_name: display_name, reviewed_at: now) }
          update!(review_status: "approved", reviewed_at: now, published_at: now)
        end
      end
      LongformTranscript.publication_callback&.call(self)
      self
    end

    def release_stale_chunks!(before: LongformTranscript.stale_after.ago)
      with_lock do
        chunks.where(status: "processing").where(claimed_at: ...before).update_all(status: "failed", retryable: true,
          failure_code: "stale_claim", failed_at: Time.current, claimed_at: nil, updated_at: Time.current)
      end
    end

    def record_source_failure!(error) = update!(status: "failed", failed_at: Time.current, failure_code: error.code)
    def audio_path = work_directory.join("source.mp3")

    private

    def published_with_complete_speaker_mappings
      expected = turns.distinct.pluck(:speaker_id).sort
      actual = speaker_mappings.where.not(display_name: "").distinct.pluck(:speaker_id).sort
      errors.add(:published_at, "requires a reviewed name for every speaker") if expected.empty? || actual != expected
    end

    def ensure_audio!
      reusable = instrument_phase("audio_cache_check") do
        audio.reusable?(sha256: source_audio_sha256, duration_ms: audio_duration_ms)
      end
      return true if reusable

      claimed = with_lock do
        next false if status == "completed"
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
        FileUtils.mv(temporary_path, audio_path)
      end
      true
    rescue ExternalFailure
      update!(audio_claimed_at: nil)
      raise
    ensure
      FileUtils.rm_f(temporary_path) if temporary_path
    end

    def prepare_chunks!(digest, duration_ms)
      return if chunks.exists?

      chunk_duration_ms = LongformTranscript.chunk_duration.in_milliseconds
      overlap_ms = LongformTranscript.chunk_overlap.in_milliseconds
      (duration_ms.to_f / chunk_duration_ms).ceil.times do |number|
        core_start = number * chunk_duration_ms
        core_end = [ (number + 1) * chunk_duration_ms, duration_ms ].min
        chunks.create!(number: number, start_ms: [ core_start - overlap_ms, 0 ].max,
          end_ms: [ core_end + overlap_ms, duration_ms ].min, source_digest: digest)
      end
    end

    def claim_next_chunk! = claim_next_chunks!(1).first

    def claim_next_chunks!(limit)
      with_lock do
        next [] if status == "completed"
        release_stale_claims
        terminal = chunks.where(status: "failed").where("retryable = ? OR retry_count >= ?", false, Chunk::MAX_RETRIES).first
        if terminal
          update!(status: "failed", failed_at: Time.current, failure_code: terminal.failure_code)
          next []
        end
        next [] if chunks.where(status: "processing").exists?

        now = Time.current
        chunks.where.not(status: "completed").ordered.limit(limit).map do |chunk|
          chunk.update!(status: "processing", retry_count: chunk.retry_count + 1, claimed_at: now,
            started_at: chunk.started_at || now, failed_at: nil, failure_code: nil)
          chunk
        end
      end
    end

    def release_stale_claims
      chunks.where(status: "processing").where(claimed_at: ...LongformTranscript.stale_after.ago).update_all(
        status: "failed", retryable: true, failure_code: "stale_claim", failed_at: Time.current,
        claimed_at: nil, updated_at: Time.current)
    end

    def process_chunks!(claimed)
      results = Queue.new
      workers = claimed.map do |chunk|
        Thread.new do
          result, latency_ms = Rails.application.executor.wrap { transcribe_chunk(chunk) }
          results << [ chunk, result, latency_ms, nil ]
        rescue StandardError => error
          results << [ chunk, nil, nil, error ]
        end
      end
      failure = nil
      claimed.size.times do
        begin
          result = ActiveSupport::Dependencies.interlock.permit_concurrent_loads { results.pop }
          record_chunk_result!(*result)
        rescue StandardError => error
          failure ||= error
        end
      end
      raise failure if failure
    ensure
      ActiveSupport::Dependencies.interlock.permit_concurrent_loads { workers&.each(&:join) }
    end

    # Only file and provider work runs in child threads; the job thread owns all database writes.
    def transcribe_chunk(chunk)
      Dir.mktmpdir("longform-transcript-chunk") do |directory|
        clip_path = Pathname(directory).join("chunk-#{chunk.number}.mp3")
        instrument_phase("clip", chunk_number: chunk.number) { create_clip!(chunk, clip_path) }
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = instrument_phase("provider", chunk_number: chunk.number) do
          Transcriber.new(model: model, profile: profile).transcribe(clip_path, chunk)
        end
        latency_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1_000).round
        [ result, latency_ms ]
      end
    end

    def record_chunk_result!(chunk, result, latency_ms, error)
      raise error if error

      # Reconciliation used to validate this before saving each chunk. Keep malformed
      # provider results retryable rather than discovering them only during assembly.
      speakers = result.turns.to_h { |turn| [ turn.fetch("speaker_id"), true ] }
      result.words.each { |word| speakers.fetch(word.fetch("speaker_id")) }
      complete_chunk!(chunk, result.turns, result.words, result.response, latency_ms)
    rescue ExternalFailure => error
      fail_chunk!(chunk, error.code, retryable: error.retryable?)
    rescue *RETRYABLE_ERRORS
      fail_chunk!(chunk, "provider_transient", retryable: true)
    rescue JSON::ParserError, KeyError, TypeError, ArgumentError => error
      log_invalid_transcription_shape(error)
      fail_chunk!(chunk, "invalid_structured_output", retryable: true)
    rescue RubyLLM::Error
      fail_chunk!(chunk, "provider_permanent", retryable: false)
    end

    def complete_chunk!(chunk, turns, words, response, latency_ms)
      with_lock do
        return unless current_claim?(chunk)

        chunk.update!(status: "completed", output: { "turns" => turns, "words" => words, "speaker_scope" => "local" },
          model: response_model(response), input_tokens: response.tokens.input.to_i,
          output_tokens: response.tokens.output.to_i, reported_cost_usd: response.tokens.reported_cost.to_d,
          latency_ms: latency_ms, completed_at: Time.current, claimed_at: nil, failure_code: nil)
      end
    end

    def fail_chunk!(chunk, code, retryable:)
      with_lock do
        return unless current_claim?(chunk)

        chunk.update!(status: "failed", retryable: retryable, failure_code: code, failed_at: Time.current, claimed_at: nil)
        update!(status: "failed", failed_at: Time.current, failure_code: code) unless chunk.retry_available?
      end
    end

    def current_claim?(chunk)
      chunks.where(id: chunk.id, status: "processing", retry_count: chunk.retry_count, claimed_at: chunk.claimed_at).exists?
    end

    def finalize_if_complete!
      with_lock do
        return true if status == "completed"
        if status == "failed" && chunks.where(status: "processing").none?
          FileUtils.rm_rf(work_directory)
          return
        end
        return unless chunks.exists? && chunks.where.not(status: "completed").none?

        LongformTranscript::Turn.where(run_id: id).delete_all
        assembled_turn_attributes.each_with_index do |attributes, position|
          turns.create!(attributes.merge(position: position))
        end
        metrics = chunks.pick(Arel.sql("COALESCE(SUM(input_tokens), 0)"),
          Arel.sql("COALESCE(SUM(output_tokens), 0)"), Arel.sql("COALESCE(SUM(reported_cost_usd), 0)"),
          Arel.sql("COALESCE(SUM(latency_ms), 0)"))
        update!(status: "completed", completed_at: Time.current, failed_at: nil, failure_code: nil,
          input_tokens: metrics[0], output_tokens: metrics[1], reported_cost_usd: metrics[2], total_latency_ms: metrics[3])
      end
      FileUtils.rm_rf(work_directory)
      true
    end

    def assembled_turn_attributes
      completed = chunks.ordered.to_a
      previous = []
      instrument_phase("speaker_reconciliation") do
        completed.each do |chunk|
          chunk.run = self
          if chunk.output["speaker_scope"] == "local"
            local_turns = chunk.output.fetch("turns")
            words = chunk.output.fetch("words")
            stable_turns = Speakers.new(previous).stabilize(local_turns, chunk, words)
            mapping = local_turns.zip(stable_turns).to_h { |local, stable| [ local.fetch("speaker_id"), stable.fetch("speaker_id") ] }
            stable_words = words.map { |word| word.merge("speaker_id" => mapping.fetch(word.fetch("speaker_id"))) }
            chunk.update!(output: { "turns" => stable_turns, "words" => stable_words })
          end
          previous << chunk
        end
      end
      instrument_phase("assembly") { Assembler.new(completed).turns }
    end

    def stabilize_speakers(turns, chunk, words = []) = Speakers.new(completed_chunks).stabilize(turns, chunk, words)
    def completed_chunks = chunks.where(status: "completed").ordered.to_a
    def response_model(response) = (response.respond_to?(:model) ? response.model : response.model_id).presence || model
    def work_directory = Pathname(storage_root).join(id.to_s)
    def storage_root = LongformTranscript.storage_root.respond_to?(:call) ? LongformTranscript.storage_root.call : LongformTranscript.storage_root
    def audio = Audio.new(audio_path)
    def download_audio!(destination, url = source_audio_url, redirects = 0) = audio.download(destination, url: url, redirects: redirects)
    def probe_duration_ms(path) = audio.duration_ms(path)
    def create_clip!(chunk, path) = audio.clip(chunk, path)

    # Kept as private compatibility seams for callers that exercised normalization directly.
    def validated_transcription(response, chunk) = Transcriber.new(model: model, profile: profile).send(:normalize_transcription, response, chunk)
    def validated_multimodal_transcription(response, chunk) = Transcriber.new(model: model, profile: profile).send(:normalize_multimodal, response, chunk)

    def log_invalid_transcription_shape(error)
      Rails.logger.warn({ event: "speaker_transcript_invalid_output", run_id: id, error_class: error.class.name,
        reason: error.respond_to?(:reason) ? error.reason : nil,
        item_index: error.respond_to?(:item_index) ? error.item_index : nil }.compact.to_json)
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
  end
end
