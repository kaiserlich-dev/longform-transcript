require "test_helper"
require "timeout"

class LongformTranscriptReplayTest < ActiveJob::TestCase
  ENDPOINT = "https://openrouter.ai/api/v1/audio/transcriptions"
  WorkerInterrupted = Class.new(StandardError)

  setup do
    @old_duration = LongformTranscript.chunk_duration
    @old_overlap = LongformTranscript.chunk_overlap
    @old_key = RubyLLM.config.openrouter_api_key
    LongformTranscript.chunk_duration = 4.seconds
    LongformTranscript.chunk_overlap = 1.second
    RubyLLM.config.openrouter_api_key = "test"
    @fixture = JSON.parse(File.read(File.expand_path("../fixtures/transcription/three_chunks.json", __dir__)))
    @run = LongformTranscript.prepare_for!(Document.create!(title: "Replay"),
      source_audio_url: "https://audio.example/replay.mp3", model: "openai/gpt-4o-mini-transcribe", profile: profile)
    FileUtils.mkdir_p(@run.audio_path.dirname)
    system("ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=11",
      "-ac", "1", "-ar", "16000", @run.audio_path.to_s, exception: true)
    @run.update!(source_audio_sha256: Digest::SHA256.file(@run.audio_path).hexdigest,
      audio_duration_ms: 11_000, status: "processing")
    @run.send(:prepare_chunks!, @run.source_audio_sha256, @run.audio_duration_ms)
  end

  teardown do
    LongformTranscript.chunk_duration = @old_duration
    LongformTranscript.chunk_overlap = @old_overlap
    RubyLLM.config.openrouter_api_key = @old_key
    FileUtils.rm_rf(@run.audio_path.dirname) if @run
  end

  test "three chunk replay preserves exact transcript and completed jobs are idempotent" do
    stub_responses(@fixture.fetch("responses"))

    finish_jobs
    assert_replay_result
    original_turn_ids = @run.turns.pluck(:id)

    assert_no_enqueued_jobs { LongformTranscript::ProcessJob.perform_now(@run.id) }
    assert_equal original_turn_ids, @run.turns.pluck(:id)
    assert_requested :post, ENDPOINT, times: 3
  end

  test "restart after a saved chunk does not call the provider again for that chunk" do
    stub_responses(@fixture.fetch("responses"))
    @run.define_singleton_method(:finalize_if_complete!) { raise WorkerInterrupted }

    assert_raises(WorkerInterrupted) { @run.process_next_chunk! }
    first = @run.chunks.first.reload
    saved_output = first.output.deep_dup
    assert_equal "completed", first.status
    assert @run.audio_path.file?, "an interruption must not remove unfinished work's audio"
    assert_empty @run.turns

    finish_jobs
    assert_replay_result
    assert_equal saved_output, first.reload.output
    assert_equal [ 1, 1, 1 ], @run.chunks.pluck(:retry_count)
    assert_requested :post, ENDPOINT, times: 3
  end

  test "invalid output retries only the failed chunk without changing the final transcript" do
    responses = @fixture.fetch("responses")
    invalid = responses[1].deep_dup
    invalid.fetch("words").first.delete("speaker")
    stub_responses([ responses[0], invalid, responses[1], responses[2] ])

    LongformTranscript::ProcessJob.perform_now(@run.id)
    clear_enqueued_jobs
    LongformTranscript::ProcessJob.perform_now(@run.id)
    clear_enqueued_jobs
    assert_equal %w[completed failed pending], @run.chunks.pluck(:status)
    assert_equal "invalid_structured_output", @run.chunks.second.failure_code
    assert @run.audio_path.file?
    assert_empty @run.turns

    finish_jobs
    assert_replay_result
    assert_equal [ 1, 2, 1 ], @run.chunks.pluck(:retry_count)
    assert_requested :post, ENDPOINT, times: 4
  end

  test "a duplicate worker cannot transcribe or finalize while another owns a live claim" do
    entered = Queue.new
    release = Queue.new
    stub_request(:post, ENDPOINT).to_return do
      entered << true
      Timeout.timeout(10) { release.pop }
      response_for(@fixture.fetch("responses").first)
    end
    worker = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        LongformTranscript::Run.find(@run.id).process_next_chunk!
      end
    end
    Timeout.timeout(10) { entered.pop }

    LongformTranscript::Run.find(@run.id).process_next_chunk!
    assert_equal %w[processing pending pending], @run.chunks.pluck(:status)
    assert_empty @run.turns
    assert @run.audio_path.file?
    assert_requested :post, ENDPOINT, times: 1

    release << true
    Timeout.timeout(10) { worker.value }
    assert_equal %w[completed pending pending], @run.chunks.pluck(:status)
  ensure
    release << true if release
    worker&.join(10)
  end

  private

  def response_for(payload)
    { status: 200, headers: { "Content-Type" => "application/json" }, body: payload.to_json }
  end

  def stub_responses(responses)
    stub_request(:post, ENDPOINT).to_return(*responses.map { |response| response_for(response) })
  end

  def finish_jobs
    Timeout.timeout(10) do
      perform_enqueued_jobs { LongformTranscript::ProcessJob.perform_later(@run.id) }
    end
  end

  def assert_replay_result
    assert_equal "completed", @run.reload.status
    assert_equal @fixture.fetch("expected_turns"), @run.turns.pluck(:position, :start_ms, :end_ms, :speaker_id, :text)
    assert_equal %w[completed completed completed], @run.chunks.pluck(:status)
    assert_equal 53, @run.input_tokens
    assert_equal 37, @run.output_tokens
    assert_equal BigDecimal("0.007"), @run.reported_cost_usd
    refute @run.audio_path.exist?
    assert_empty enqueued_jobs
  end
end
