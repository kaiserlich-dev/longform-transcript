require "test_helper"

class LongformTranscriptTranscriberTest < ActiveSupport::TestCase
  FakeTranscription = Data.define(:text, :segments, :words)

  test "normalizes provider words into stable local speakers and independently sorted timestamps" do
    chunk = prepared_chunk
    response = FakeTranscription.new("first second", [], [
      { speaker: "guest", start: 0.7, end: 0.9, word: "second" },
      { speaker: "host", start: 0.1, end: 0.4, word: "first" }
    ])

    turns, words = transcriber.send(:normalize_transcription, response, chunk)

    assert_equal [ "first", "second" ], words.pluck("text")
    assert_equal [ 100, 700 ], words.pluck("start_ms")
    assert_equal %w[speaker_1 speaker_2], words.pluck("speaker_id")
    assert_equal [ "first", "second" ], turns.pluck("text")
  end

  test "rejects a word that extends beyond the chunk tolerance" do
    response = FakeTranscription.new("late", [], [
      { speaker: "host", start: 59.0, end: 62.0, word: "late" }
    ])

    error = assert_raises(LongformTranscript::Transcriber::InvalidOutput) do
      transcriber.send(:normalize_transcription, response, prepared_chunk)
    end
    assert_equal "out_of_range", error.reason
    assert_equal 0, error.item_index
  end

  test "accepts a blank transcription when timing collections are absent or empty" do
    [ [ nil, nil ], [ [], [] ] ].each do |segments, words|
      assert_equal [ [], [] ], transcriber.send(
        :normalize_transcription, FakeTranscription.new("  ", segments, words), prepared_chunk)
    end
  end

  test "rejects transcription text without timed words" do
    [ nil, [] ].each do |words|
      error = assert_raises(LongformTranscript::Transcriber::InvalidOutput) do
        transcriber.send(:normalize_transcription, FakeTranscription.new("Spoken text", [], words), prepared_chunk)
      end

      assert_equal "missing_timed_words", error.reason
      assert_nil error.item_index
    end
  end

  private

  def transcriber
    LongformTranscript::Transcriber.new(model: "provider/model", profile: profile)
  end

  def prepared_chunk
    run = prepared_run
    prepare_chunks(run, duration: 60_000).first
  end
end
