module LongformTranscript
  class Assembler
    def initialize(chunks)
      @chunks = chunks
    end

    def turns
      seen = {}
      assembled = chunks.flat_map do |chunk|
        timestamped_turns(chunk).filter_map do |turn|
          midpoint = (turn.fetch("start_ms") + turn.fetch("end_ms")) / 2
          next unless midpoint >= chunk.core_start_ms && midpoint < chunk.core_end_ms

          duplicate_key = [ turn.fetch("speaker_id"), Text.normalize(turn.fetch("text")) ]
          next if seen[duplicate_key]

          seen[duplicate_key] = true
          { chunk: chunk, start_ms: turn.fetch("start_ms"), end_ms: turn.fetch("end_ms"),
            speaker_id: turn.fetch("speaker_id"), text: turn.fetch("text") }
        end
      end.sort_by { |turn| [ turn.fetch(:start_ms), turn.fetch(:end_ms), turn.fetch(:speaker_id) ] }
      trim_boundary_overlaps(assembled)
    end

    private

    attr_reader :chunks

    def timestamped_turns(chunk)
      words = chunk.output.fetch("words", [])
      return chunk.output.fetch("turns") if words.empty?

      words.filter do |word|
        midpoint = (word.fetch("start_ms") + word.fetch("end_ms")) / 2
        midpoint >= chunk.core_start_ms && midpoint < chunk.core_end_ms
      end.chunk_while do |left, right|
        left.fetch("speaker_id") == right.fetch("speaker_id")
      end.map do |passage|
        { "speaker_id" => passage.first.fetch("speaker_id"), "start_ms" => passage.first.fetch("start_ms"),
          "end_ms" => passage.last.fetch("end_ms"), "text" => Text.words(passage) }
      end
    end

    def trim_boundary_overlaps(turns)
      turns.each_with_object([]) do |turn, result|
        previous = result.last(6).reverse.find do |candidate|
          candidate.fetch(:speaker_id) == turn.fetch(:speaker_id) && candidate.fetch(:chunk).id != turn.fetch(:chunk).id
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
      pairs = Text.longest_common_subsequence(previous_tokens.map(&:first), current_tokens.map(&:first))
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
  end
end
