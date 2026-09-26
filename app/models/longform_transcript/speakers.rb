module LongformTranscript
  class Speakers
    def initialize(completed_chunks)
      @completed_chunks = completed_chunks
    end

    def stabilize(turns, chunk, words = [])
      previous_output = completed_chunks.find { |candidate| candidate.number == chunk.number - 1 }&.output || {}
      previous = previous_output.fetch("turns", [])
      mapping = word_mapping(previous_output.fetch("words", []), words)
      used = mapping.values
      turns.each do |turn|
        next if mapping.key?(turn.fetch("speaker_id"))

        match = previous.reject { |candidate| used.include?(candidate.fetch("speaker_id")) }.max_by do |candidate|
          overlap_score(turn.fetch("text"), candidate.fetch("text"))
        end
        next unless match && overlap_score(turn.fetch("text"), match.fetch("text")).positive?

        mapping[turn.fetch("speaker_id")] ||= match.fetch("speaker_id")
        used << match.fetch("speaker_id")
      end

      known = completed_chunks.select { |candidate| candidate.number < chunk.number }
        .flat_map { |candidate| candidate.output.fetch("turns", []).pluck("speaker_id") }
        .uniq.sort_by { |speaker| speaker[/\d+\z/].to_i }
      available = known - used
      next_number = known.filter_map { |speaker| speaker[/\d+\z/].to_i }.max.to_i + 1
      turns.map do |turn|
        local = turn.fetch("speaker_id")
        mapping[local] ||= available.shift || "speaker_#{next_number}".tap { next_number += 1 }
        turn.merge("speaker_id" => mapping.fetch(local))
      end
    end

    private

    attr_reader :completed_chunks

    def word_mapping(previous_words, words)
      candidates = previous_words.group_by { |word| word.fetch("speaker_id") }.transform_values do |speaker_words|
        speaker_words.group_by { |word| Text.normalize(word.fetch("text")) }.transform_values do |token_words|
          token_words.pluck("start_ms").sort
        end
      end
      mapping = {}
      used = []
      words.group_by { |word| word.fetch("speaker_id") }.each do |local_speaker, local_words|
        tokens = local_words.map { |word| [ Text.normalize(word.fetch("text")), word.fetch("start_ms") ] }
        votes = candidates.to_h do |stable_speaker, token_times|
          matches = tokens.count do |token, start_ms|
            next false if token.blank?

            candidate = token_times[token]&.bsearch { |time| time >= start_ms - 250 }
            candidate && candidate <= start_ms + 250
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

    def overlap_score(left, right)
      left_words = Text.normalize(left).split.first(80)
      right_words = Text.normalize(right).split.last(80)
      shorter_length = [ left_words.length, right_words.length ].min
      return 0 if shorter_length < 4

      score = Text.longest_common_subsequence(left_words, right_words).length
      left_words == right_words || (score >= 6 && score.fdiv(shorter_length) >= 0.6) ? score : 0
    end
  end
end
