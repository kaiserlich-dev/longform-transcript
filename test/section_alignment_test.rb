require "test_helper"

class SectionAlignmentTest < ActiveSupport::TestCase
  Turn = Data.define(:text, :start_ms, :end_ms)
  Section = Data.define(:id, :text)

  test "fuzzily splits passages at every ordered section boundary" do
    sections = [
      Section.new("first", "Alpha opening has enough words for a reliable match."),
      Section.new("second", "Chapter two begins with changed wording in this transcript."),
      Section.new("third", "Third boundary starts with another distinct sentence here.")
    ]
    turn = Turn.new(
      "Alpha opening has enough words for a reliable match. " \
        "Chapter two begins with slightly changed wording in this transcript. " \
        "Third boundary starts with another distinct sentence here.",
      1_000, 10_000
    )

    fragments = align(sections, [ [ turn ] ])

    assert_equal %w[first second third], fragments.flat_map { |fragment| fragment.fetch(:sections).map(&:id) }
    assert_equal turn.text, fragments.map { |fragment| fragment.fetch(:text) }.join(" ")
    assert fragments.find { |fragment| fragment.fetch(:sections).first&.id == "second" }
      .fetch(:text).start_with?("Chapter two begins")
    assert_equal [ 1_000, 10_000 ], [ fragments.first.fetch(:start_ms), fragments.last.fetch(:end_ms) ]
  end

  test "uses exact word timings instead of proportional timestamps" do
    turn = Turn.new("Alpha opening. Beta closing.", 1_000, 20_000)
    words = [ [ "Alpha", 1_000, 2_000 ], [ "opening.", 2_000, 3_000 ],
      [ "Beta", 15_000, 16_000 ], [ "closing.", 16_000, 20_000 ] ].map do |text, from, to|
      { "text" => text, "start_ms" => from, "end_ms" => to }
    end

    fragments = align(section_pair, [ [ turn ] ], words: words)

    assert_equal [ 1_000, 15_000 ], fragments.map { |fragment| fragment.fetch(:start_ms) }
    assert_equal [ 3_000, 20_000 ], fragments.map { |fragment| fragment.fetch(:end_ms) }
    assert_equal words.each_slice(2).to_a, fragments.map { |fragment| fragment.fetch(:words) }
  end

  test "retains every marker and word when sections outnumber unmatched tokens" do
    turn = Turn.new("Only two", 0, 2_000)
    sections = %w[one two three four].map { |id| Section.new(id, "Unmatched source wording") }

    fragments = align(sections, [ [ turn ] ])

    assert_equal %w[one two three four], fragments.flat_map { |fragment| fragment.fetch(:sections).map(&:id) }
    assert_equal "Only two", fragments.map { |fragment| fragment.fetch(:text) }.join(" ")
    assert_equal [ 0, 1_000 ], fragments.map { |fragment| fragment.fetch(:start_ms) }
  end

  test "exact sections preserve turn timestamps through repeated text and long pauses" do
    turns = [ Turn.new("Repeated opening.", 100, 900), Turn.new("Other context.", 2_000, 3_000),
      Turn.new("Repeated opening.", 90_000, 95_000) ]
    sections = [ Section.new("one", "Repeated opening. Other context."),
      Section.new("two", "Repeated opening.") ]

    fragments = align(sections, [ turns ])

    assert_equal [ "Repeated opening. Other context.", "Repeated opening." ], fragments.map { |fragment| fragment.fetch(:text) }
    assert_equal [ 100, 90_000 ], fragments.map { |fragment| fragment.fetch(:start_ms) }
    assert_equal [ 3_000, 95_000 ], fragments.map { |fragment| fragment.fetch(:end_ms) }
  end

  test "finds a passage's words without scanning the full timing array" do
    counter = { fetches: 0 }
    counting_word = Class.new(Hash) do
      define_method(:initialize) { |values| super().merge!(values) }
      define_method(:fetch) do |key|
        counter[:fetches] += 1
        super(key)
      end
    end
    words = 10_000.times.map do |index|
      counting_word.new("text" => "word-#{index}", "start_ms" => index * 100, "end_ms" => (index + 1) * 100)
    end
    turn = Turn.new("word-5000 word-5001", 500_000, 500_200)

    fragments = align([ Section.new("one", turn.text) ], [ [ turn ] ], words: words)

    assert_equal %w[word-5000 word-5001], fragments.first.fetch(:words).map { |word| word.fetch("text") }
    assert_operator counter.fetch(:fetches), :<, 100
  end

  test "requires callers to define how section text is read" do
    error = assert_raises(ArgumentError) do
      LongformTranscript.align_sections(sections: section_pair, passages: [])
    end

    assert_equal "a block returning each section's transcript text is required", error.message
  end

  private

  def align(sections, passages, words: [])
    LongformTranscript.align_sections(sections: sections, passages: passages, words: words, &:text)
  end

  def section_pair
    [ Section.new("one", "Alpha opening."), Section.new("two", "Beta closing.") ]
  end
end
