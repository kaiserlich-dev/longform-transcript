require "test_helper"

class LongformTranscriptSpeakersTest < ActiveSupport::TestCase
  test "word matching needs two votes within the inclusive 250 millisecond tolerance" do
    first, second = prepare_chunks(prepared_run)
    first.update!(status: "completed", output: {
      "turns" => [
        { "speaker_id" => "speaker_1", "text" => "Host" },
        { "speaker_id" => "speaker_2", "text" => "Guest" }
      ],
      "words" => [
        word("speaker_1", 280_000, "Echo"), word("speaker_1", 281_000, "echo"),
        word("speaker_2", 298_000, "Echo!"), word("speaker_2", 299_000, "echo")
      ]
    })
    speakers = LongformTranscript::Speakers.new([ first ])
    turns = [ { "speaker_id" => "local", "text" => "Unrelated passage" } ]

    [ -251, -250, 0, 250, 251 ].each do |delta|
      incoming = [ word("local", 298_000 + delta, "ECHO"), word("local", 299_000 + delta, "echo.") ]
      expected = delta.abs <= 250 ? "speaker_2" : "speaker_1"
      assert_equal expected, speakers.stabilize(turns, second, incoming).sole.fetch("speaker_id"), "offset #{delta}"
    end

    assert_equal "speaker_1", speakers.stabilize(turns, second, [ word("local", 298_000, "echo") ]).sole.fetch("speaker_id"),
      "one matching word is insufficient even when the previous chunk repeats the token"
  end

  test "two local speakers cannot both claim the same stable speaker" do
    first, second = prepare_chunks(prepared_run)
    first.update!(status: "completed", output: {
      "turns" => [ { "speaker_id" => "speaker_1", "text" => "Host" }, { "speaker_id" => "speaker_2", "text" => "Guest" } ],
      "words" => [ word("speaker_2", 298_000, "green"), word("speaker_2", 299_000, "trees") ]
    })
    turns = [ { "speaker_id" => "a", "text" => "First" }, { "speaker_id" => "b", "text" => "Second" } ]
    words = [ word("a", 298_000, "green"), word("a", 299_000, "trees"),
      word("b", 298_000, "green"), word("b", 299_000, "trees") ]

    result = LongformTranscript::Speakers.new([ first ]).stabilize(turns, second, words)

    assert_equal %w[speaker_2 speaker_1], result.pluck("speaker_id")
  end

  test "word mapping agrees with exhaustive matching across repeated tokens timestamps and ties" do
    random = Random.new(20260926)
    speakers = LongformTranscript::Speakers.new([])
    100.times do |sample|
      previous = 40.times.map do
        word("speaker_#{random.rand(1..3)}", random.rand(0..20) * 100, [ "Echo!", "TREE", "", "river" ].sample(random: random))
      end.shuffle(random: random)
      incoming = previous.sample(20, random: random).map do |candidate|
        word("local_#{random.rand(1..3)}", candidate.fetch("start_ms") + [ -251, -250, 0, 250, 251 ].sample(random: random),
          candidate.fetch("text").downcase)
      end
      expected = {}
      candidates = previous.group_by { |item| item.fetch("speaker_id") }
      incoming.group_by { |item| item.fetch("speaker_id") }.each do |local, words|
        votes = candidates.map do |stable, prior|
          count = words.count do |item|
            token = LongformTranscript::Text.normalize(item.fetch("text"))
            token.present? && prior.any? do |candidate|
              token == LongformTranscript::Text.normalize(candidate.fetch("text")) &&
                (item.fetch("start_ms") - candidate.fetch("start_ms")).abs <= 250
            end
          end
          [ stable, count ]
        end
        stable, count = votes.reject { |speaker, _| expected.value?(speaker) }.max_by(&:last)
        expected[local] = stable if count.to_i >= 2
      end

      assert_equal expected, speakers.send(:word_mapping, previous, incoming), "sample #{sample}"
    end
  end

  private

  def word(speaker, start_ms, text)
    { "speaker_id" => speaker, "start_ms" => start_ms, "end_ms" => start_ms + 100, "text" => text }
  end
end
