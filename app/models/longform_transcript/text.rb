module LongformTranscript
  module Text
    module_function

    def normalize(text)
      text.to_s.downcase.gsub(/[^[:alnum:]]+/, " ").squish
    end

    def words(items)
      items.pluck("text").join(" ").gsub(/\s+([,.;:!?])/, "\\1")
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
  end
end
