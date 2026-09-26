require "test_helper"

class LongformTranscriptTest < ActiveSupport::TestCase
  test "prepare is idempotent, canonicalizes identity, and persists profile" do
    document = Document.create!(title: "Show")
    first = LongformTranscript.prepare_for!(document, source_audio_url: "https://audio.example/a.mp3?one=1#x",
      model: "model", profile: profile)
    second = LongformTranscript.prepare_for!(document, source_audio_url: "https://audio.example/a.mp3?two=2",
      model: "model", profile: profile)

    assert_equal first, second
    assert_equal "https://audio.example/a.mp3?two=2", second.source_audio_url
    assert_equal "test-v1", second.profile.fetch("version")
  end

  test "claims are ordered, exclusive, stale-resumable, and bounded" do
    run = prepared_run(url: "https://example.com/show.mp3")
    first = prepare_chunks(run).first
    assert_equal first, run.send(:claim_next_chunk!)
    assert_nil run.send(:claim_next_chunk!)
    first.update!(claimed_at: 31.minutes.ago)
    assert_equal 2, run.send(:claim_next_chunk!).retry_count
    first.update!(status: "failed", retry_count: 3, failure_code: "provider_transient")
    assert_nil run.send(:claim_next_chunk!)
    assert_equal "failed", run.reload.status
  end

  test "assembly owns overlap by chunk core and removes duplicate turns" do
    run = prepared_run
    first, second = prepare_chunks(run)
    first.update!(status: "completed", output: { "turns" => [
      { "speaker_id" => "speaker_1", "start_ms" => 0, "end_ms" => 1_000, "text" => "Start" },
      { "speaker_id" => "speaker_1", "start_ms" => 299_000, "end_ms" => 301_000, "text" => "Boundary" }
    ] })
    second.update!(status: "completed", output: { "turns" => [
      { "speaker_id" => "speaker_1", "start_ms" => 299_000, "end_ms" => 301_000, "text" => "Boundary" },
      { "speaker_id" => "speaker_2", "start_ms" => 301_000, "end_ms" => 302_000, "text" => "Reply" }
    ] })
    run.send(:finalize_if_complete!)
    assert_equal %w[Start Boundary Reply], run.turns.pluck(:text)
  end

  test "speaker stabilization uses overlap words and neutral IDs" do
    run = prepared_run
    first, second = prepare_chunks(run)
    first.update!(status: "completed", output: { "turns" => [], "words" => [
      { "speaker_id" => "speaker_2", "start_ms" => 298_000, "end_ms" => 298_200, "text" => "same" },
      { "speaker_id" => "speaker_2", "start_ms" => 298_400, "end_ms" => 298_600, "text" => "voice" }
    ] })
    incoming = [ { "speaker_id" => "local", "start_ms" => 298_000, "end_ms" => 302_000, "text" => "same voice" } ]
    words = [
      { "speaker_id" => "local", "start_ms" => 298_020, "end_ms" => 298_220, "text" => "same" },
      { "speaker_id" => "local", "start_ms" => 298_420, "end_ms" => 298_620, "text" => "voice" }
    ]
    assert_equal "speaker_2", run.send(:stabilize_speakers, incoming, second, words).sole.fetch("speaker_id")
  end

  test "publication atomically replaces a run and stores complete mappings" do
    document = Document.create!(title: "Show")
    old = LongformTranscript.prepare_for!(document, source_audio_url: "https://audio.example/old.mp3", model: "m", profile: profile)
    newer = LongformTranscript.prepare_for!(document, source_audio_url: "https://audio.example/new.mp3", model: "m", profile: profile)
    [ old, newer ].each do |run|
      chunk = prepare_chunks(run, duration: 1_000).sole
      chunk.update!(status: "completed", output: { "turns" => [
        { "speaker_id" => "speaker_1", "start_ms" => 0, "end_ms" => 900, "text" => "Hello" }
      ] })
      run.send(:finalize_if_complete!)
    end
    old.publish!(speaker_1: "Old")
    newer.publish!(speaker_1: "Host")
    assert_nil old.reload.published_at
    assert_predicate newer.reload, :published_at?
    assert_equal({ "speaker_1" => "Host" }, newer.speaker_mappings.pluck(:speaker_id, :display_name).to_h)
  end

  test "download boundary rejects non-HTTPS, private addresses, and oversized responses" do
    run = prepared_run(url: "https://example.com/show.mp3")
    assert_raises(ArgumentError) { LongformTranscript::Run.canonical_audio_url("http://example.com/a.mp3") }
    assert run.send(:blocked_address?, "127.0.0.1")
    LongformTranscript.download_limit = 3
    stub_request(:get, run.source_audio_url).to_return(body: "four")
    error = assert_raises(LongformTranscript::Run::ExternalFailure) do
      Dir.mktmpdir { |dir| run.send(:download_audio!, Pathname(dir).join("audio")) }
    end
    assert_equal "audio_too_large", error.code
  ensure
    LongformTranscript.download_limit = 1024**3
  end

  test "job processes one chunk and schedules continuation only when work remains" do
    run = prepared_run
    original_process = LongformTranscript::Run.instance_method(:process_next_chunk!)
    original_remaining = LongformTranscript::Run.instance_method(:work_remaining?)
    LongformTranscript::Run.define_method(:process_next_chunk!) { update!(failure_code: "processed") }
    LongformTranscript::Run.define_method(:work_remaining?) { true }
    assert_enqueued_with(job: LongformTranscript::ProcessJob, args: [ run.id ]) do
      LongformTranscript::ProcessJob.perform_now(run.id)
    end
    assert_equal "processed", run.reload.failure_code
  ensure
    LongformTranscript::Run.define_method(:process_next_chunk!, original_process) if original_process
    LongformTranscript::Run.define_method(:work_remaining?, original_remaining) if original_remaining
  end
end
