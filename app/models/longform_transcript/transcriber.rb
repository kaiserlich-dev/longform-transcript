module LongformTranscript
  class Transcriber
    Result = Data.define(:response, :turns, :words)

    class InvalidOutput < ArgumentError
      attr_reader :reason, :item_index

      def initialize(reason, item_index = nil)
        @reason = reason
        @item_index = item_index
        super(item_index ? "#{reason} at word #{item_index}" : reason)
      end
    end

    def initialize(model:, profile:)
      @model = model
      @profile = profile.to_h.deep_symbolize_keys
    end

    def transcribe(path, chunk)
      interface == :multimodal_chat ? transcribe_multimodal(path, chunk) : transcribe_audio(path, chunk)
    end

    private

    attr_reader :model, :profile

    def interface = profile.fetch(:interface).to_sym
    def provider = profile.fetch(:provider, :openrouter).to_sym

    def transcribe_multimodal(path, chunk)
      response = RubyLLM.chat(model: model, provider: provider)
        .with_temperature(0).with_schema(LongformTranscript::TranscriptSchema)
        .ask(multimodal_prompt(chunk), with: path.to_s)
      Result.new(response, normalize_multimodal(response, chunk), [])
    end

    def transcribe_audio(path, chunk)
      options = {
        model: model, provider: provider, format: "verbose_json", timestamps: [ :segment, :word ],
        provider_options: { provider: profile.fetch(:provider_options, {}) }
      }
      options[:language] = profile.fetch(:language) if profile[:language].present?
      response = RubyLLM.transcribe(path.to_s, **options)
      turns, words = normalize_transcription(response, chunk)
      Result.new(response, turns, words)
    end

    def multimodal_prompt(chunk)
      return profile.fetch(:instructions) if profile[:instructions].present?

      <<~PROMPT
        Transcribe this recording verbatim and completely in its original language.
        Separate every speaker change. Use only neutral speaker IDs such as speaker_1 and speaker_2;
        do not invent names. start_ms and end_ms are precise milliseconds relative to the beginning of this
        #{chunk.end_ms - chunk.start_ms} millisecond audio excerpt. All timestamps must be monotonic and within
        the excerpt, and end_ms must be greater than start_ms. Return only the structured result.
      PROMPT
    end

    def normalize_multimodal(response, chunk)
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

    def normalize_transcription(response, chunk)
      words = response.words
      segments = response.segments
      return [ [], [] ] if response.text.blank? && [ words, segments ].all? { |items| items.nil? || items.empty? }
      raise InvalidOutput.new("missing_timed_words") unless words.is_a?(Array) && words.any?

      duration = chunk.end_ms - chunk.start_ms
      timestamped_words = words.map.with_index { |item, index| normalize_word(item, index, duration) }
        .sort_by { |word| [ word.fetch(:start_ms), word.fetch(:item_index) ] }
      speakers = {}
      normalized_words = timestamped_words.map do |word|
        speaker = speakers[word.fetch(:raw_speaker)] ||= "speaker_#{speakers.length + 1}"
        { "speaker_id" => speaker, "start_ms" => word.fetch(:start_ms) + chunk.start_ms,
          "end_ms" => [ word.fetch(:end_ms), duration ].min + chunk.start_ms, "text" => word.fetch(:text) }
      end
      turns = normalize_segments(segments, speakers, chunk) || turns_from_words(normalized_words)
      [ turns, normalized_words ]
    end

    def normalize_word(item, index, duration)
      item = item.deep_stringify_keys
      speaker = item.fetch("speaker").to_s
      text = item.fetch("word") { item.fetch("text") }.to_s.squish
      raise InvalidOutput.new("missing_speaker", index) if speaker.blank?
      raise InvalidOutput.new("blank_text", index) if text.blank?

      begin
        start_ms = (Float(item.fetch("start")) * 1_000).round
        end_ms = (Float(item.fetch("end")) * 1_000).round
      rescue KeyError, TypeError, ArgumentError
        raise InvalidOutput.new("invalid_numeric_timestamp", index)
      end
      raise InvalidOutput.new("negative_start", index) if start_ms.negative?
      raise InvalidOutput.new("nonpositive_duration", index) if end_ms <= start_ms
      raise InvalidOutput.new("out_of_range", index) if end_ms > duration + 1_000

      { raw_speaker: speaker, text: text, start_ms: start_ms, end_ms: end_ms, item_index: index }
    end

    def normalize_segments(segments, speakers, chunk)
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

    def turns_from_words(words)
      words.chunk_while { |left, right| left.fetch("speaker_id") == right.fetch("speaker_id") }.map do |passage|
        { "speaker_id" => passage.first.fetch("speaker_id"), "start_ms" => passage.first.fetch("start_ms"),
          "end_ms" => passage.last.fetch("end_ms"), "text" => Text.words(passage) }
      end
    end
  end
end
