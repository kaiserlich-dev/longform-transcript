module LongformTranscript
  class SectionAlignment
    class << self
      def call(sections:, passages:, words: [], &section_text)
        new(sections, passages, words, section_text).call
      end
    end

    def initialize(sections, passages, words, section_text)
      raise ArgumentError, "a block returning each section's transcript text is required" unless section_text

      @sections = sections
      @passages = passages
      @words = words
      @section_text = section_text
    end

    def call
      details = passages.map do |passage|
        tokens = passage.flat_map { |turn| turn.text.split.map { |text| { text: text, turn: turn } } }
        timings = passage_words(passage)
        { passage: passage, tokens: tokens, timings: timings.length == tokens.length ? timings : [] }
      end
      all_tokens = details.flat_map { |detail| detail.fetch(:tokens) }
      return [] if all_tokens.empty?

      sections_by_token = section_boundaries(all_tokens)
      token_offset = 0
      details.flat_map do |detail|
        entries = passage_entries(detail, sections_by_token, token_offset)
        token_offset += detail.fetch(:tokens).length
        entries
      end
    end

    private

    attr_reader :sections, :passages, :words, :section_text

    def passage_words(passage)
      first = words.bsearch_index { |word| word_midpoint(word) >= passage.first.start_ms }
      return [] unless first

      last = words.bsearch_index { |word| word_midpoint(word) >= passage.last.end_ms } || words.length
      candidates = words.slice(first...last)
      expected = passage.map(&:text).join(" ").split
      actual = candidates.map { |word| word.fetch("text") }
      offset = actual.each_index.find { |index| actual.slice(index, expected.length) == expected }
      offset ? candidates.slice(offset, expected.length) : []
    end

    def word_midpoint(word)
      (word.fetch("start_ms") + word.fetch("end_ms")) / 2
    end

    def passage_entries(detail, sections_by_token, token_offset)
      tokens = detail.fetch(:tokens)
      passage_sections = sections_by_token.filter_map do |index, section|
        [ index - token_offset, section ] if index.between?(token_offset, token_offset + tokens.length - 1)
      end
      boundaries = ([ 0, tokens.length ] + passage_sections.map(&:first)).uniq.sort
      boundaries.each_cons(2).filter_map do |from, to|
        next if from == to

        fragment(detail, passage_sections, from, to)
      end
    end

    def fragment(detail, passage_sections, from, to)
      tokens = detail.fetch(:tokens)
      fragment_tokens = tokens.slice(from...to)
      fragment_words = detail.fetch(:timings).slice(from...to) || []
      passage = detail.fetch(:passage)
      start_ms, end_ms = fragment_bounds(passage, fragment_words, from, to, tokens.length)
      if fragment_words.empty? && starts_on_turn_boundary?(tokens, fragment_tokens, from) &&
          ends_on_turn_boundary?(tokens, fragment_tokens, to)
        start_ms = fragment_tokens.first.fetch(:turn).start_ms
        end_ms = fragment_tokens.last.fetch(:turn).end_ms
      end
      {
        sections: passage_sections.select { |position, _| position == from }.map(&:last),
        first_turn: fragment_tokens.first.fetch(:turn), last_turn: fragment_tokens.last.fetch(:turn),
        text: fragment_tokens.map { |token| token.fetch(:text) }.join(" "), words: fragment_words,
        start_ms: start_ms, end_ms: end_ms
      }
    end

    def starts_on_turn_boundary?(tokens, fragment_tokens, from)
      from.zero? || tokens.fetch(from - 1).fetch(:turn) != fragment_tokens.first.fetch(:turn)
    end

    def ends_on_turn_boundary?(tokens, fragment_tokens, to)
      to == tokens.length || tokens.fetch(to).fetch(:turn) != fragment_tokens.last.fetch(:turn)
    end

    def section_boundaries(tokens)
      source_tokens = sections.map { |section| section_text.call(section).to_s.split }
      if source_tokens.flatten == tokens.map { |token| token.fetch(:text) }
        offset = 0
        return sections.map.with_index do |section, index|
          boundary = [ offset, section ]
          offset += source_tokens.fetch(index).size
          boundary
        end
      end

      normalized_tokens = tokens.each_with_index.flat_map do |token, raw_index|
        normalize(token.fetch(:text)).split.map { |text| { text: text, raw_index: raw_index } }
      end
      return [] if normalized_tokens.empty?

      fuzzy_boundaries(tokens, normalized_tokens)
    end

    def fuzzy_boundaries(tokens, normalized_tokens)
      token_positions = normalized_tokens.each_index.group_by do |index|
        normalized_tokens.fetch(index).fetch(:text)
      end
      source_words = sections.map { |section| normalize(section_text.call(section)).split }
      source_lengths = source_words.map(&:length)
      source_total = source_lengths.sum
      source_offset = 0
      previous_raw_index = -1

      sections.map.with_index do |section, index|
        expected_index = source_total.positive? ?
          (source_offset.fdiv(source_total) * normalized_tokens.length).round : 0
        expected_index = expected_index.clamp(0, normalized_tokens.length - 1)
        expected_raw_index = normalized_tokens.fetch(expected_index).fetch(:raw_index)
        matched_index = boundary_match(source_words.fetch(index).first(16), normalized_tokens,
          token_positions, expected_raw_index, previous_raw_index)
        raw_index = matched_index ? normalized_tokens.fetch(matched_index).fetch(:raw_index) : expected_raw_index

        remaining_sections = sections.length - index - 1
        maximum_raw_index = [ tokens.length - remaining_sections - 1, 0 ].max
        raw_index = raw_index.clamp(previous_raw_index + 1, [ maximum_raw_index, previous_raw_index + 1 ].max)
        raw_index = tokens.length - 1 if raw_index >= tokens.length
        previous_raw_index = raw_index
        source_offset += source_lengths.fetch(index)
        [ raw_index, section ]
      end
    end

    def boundary_match(needle, tokens, token_positions, expected_raw_index, previous_raw_index)
      return if needle.empty?

      radius = [ 250, tokens.last.fetch(:raw_index) / 5 ].max
      candidates = needle.first(8).each_with_index.flat_map do |word, needle_index|
        token_positions.fetch(word, []).filter_map do |token_index|
          start = token_index - needle_index
          next if start.negative?

          raw_index = tokens.fetch(start).fetch(:raw_index)
          start if raw_index > previous_raw_index && (raw_index - expected_raw_index).abs <= radius
        end
      end.uniq.sort_by do |start|
        (tokens.fetch(start).fetch(:raw_index) - expected_raw_index).abs
      end.first(24)
      match = candidates.max_by do |start|
        candidate = tokens.slice(start, needle.length + 8).to_a.map { |token| token.fetch(:text) }
        prefix = candidate.first(needle.length)
        [ word_matches(needle, candidate), prefix.first == needle.first ? 1 : 0,
          -word_distance(needle, prefix), -(tokens.fetch(start).fetch(:raw_index) - expected_raw_index).abs ]
      end
      minimum_matches = [ 4, needle.length ].min
      match if match && word_matches(needle,
        tokens.slice(match, needle.length + 8).to_a.map { |token| token.fetch(:text) }) >= minimum_matches
    end

    def fragment_bounds(passage, fragment_words, from, to, token_count)
      return [ fragment_words.first.fetch("start_ms"), fragment_words.last.fetch("end_ms") ] if fragment_words.any?

      start_ms = passage.first.start_ms
      duration = passage.last.end_ms - start_ms
      [ start_ms + (duration * from.fdiv(token_count)).round,
        start_ms + (duration * to.fdiv(token_count)).round ]
    end

    def normalize(text)
      text.to_s.downcase.gsub(/[^[:alnum:]]+/, " ").strip.gsub(/\s+/, " ")
    end

    def word_matches(left, right)
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
      lengths.last.last
    end

    def word_distance(left, right)
      distances = (0..right.length).to_a
      left.each_with_index do |left_word, left_index|
        next_distances = [ left_index + 1 ]
        right.each_with_index do |right_word, right_index|
          next_distances << [ distances.fetch(right_index + 1) + 1, next_distances.fetch(right_index) + 1,
            distances.fetch(right_index) + (left_word == right_word ? 0 : 1) ].min
        end
        distances = next_distances
      end
      distances.last
    end
  end
end
