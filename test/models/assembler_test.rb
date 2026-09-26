require "test_helper"

class LongformTranscriptAssemblerTest < ActiveSupport::TestCase
  test "word midpoints immediately before at and after a boundary belong to exactly one core" do
    chunks = prepare_chunks(prepared_run)
    words = [
      { "speaker_id" => "speaker_1", "start_ms" => 299_998, "end_ms" => 300_000, "text" => "Before" },
      { "speaker_id" => "speaker_1", "start_ms" => 299_999, "end_ms" => 300_001, "text" => "exact" },
      { "speaker_id" => "speaker_1", "start_ms" => 300_000, "end_ms" => 300_002, "text" => "after" }
    ]
    chunks.each { |chunk| chunk.update!(status: "completed", output: { "words" => words, "turns" => [] }) }

    result = LongformTranscript::Assembler.new(chunks).turns

    assert_equal [
      { chunk: chunks.first, start_ms: 299_998, end_ms: 300_000, speaker_id: "speaker_1", text: "Before" },
      { chunk: chunks.second, start_ms: 299_999, end_ms: 300_002, speaker_id: "speaker_1", text: "exact after" }
    ], result
  end
end
