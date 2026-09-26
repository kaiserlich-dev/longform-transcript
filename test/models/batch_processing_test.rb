require "test_helper"
require "timeout"

class LongformTranscriptBatchProcessingTest < ActiveSupport::TestCase
  Response = Data.define(:segments, :words, :model, :tokens)

  setup do
    @old_duration, @old_overlap = LongformTranscript.chunk_duration, LongformTranscript.chunk_overlap
    LongformTranscript.chunk_duration = 4.seconds
    LongformTranscript.chunk_overlap = 1.second
    @fixture = JSON.parse(File.read(File.expand_path("../fixtures/transcription/three_chunks.json", __dir__)))
    @run = prepared_run
    FileUtils.mkdir_p(@run.audio_path.dirname)
    File.binwrite(@run.audio_path, "cached audio")
    @run.update!(source_audio_sha256: Digest::SHA256.file(@run.audio_path).hexdigest, audio_duration_ms: 11_000,
      status: "processing")
    @run.send(:prepare_chunks!, @run.source_audio_sha256, @run.audio_duration_ms)
    @workers = []
    @gates = []
  end

  teardown do
    @gates.each { |gate| 3.times { gate << true } }
    @workers.each { |worker| worker.join(10) }
    LongformTranscript.chunk_duration, LongformTranscript.chunk_overlap = @old_duration, @old_overlap
    FileUtils.rm_rf(@run.audio_path.dirname)
  end

  test "bounded parallel requests persist out of order but assemble the exact sequential transcript" do
    entered, saved = Queue.new, Queue.new
    gates = 2.times.map { new_gate }
    install_transcriber(@run) do |chunk|
      entered << chunk.number
      Timeout.timeout(5) { gates.fetch(chunk.number).pop }
    end
    @run.define_singleton_method(:complete_chunk!) do |*args|
      super(*args)
      saved << args.first.number
    end
    worker = start_worker { @run.process_next_batch!(limit: 2) }
    assert_equal [ 0, 1 ], 2.times.map { Timeout.timeout(5) { entered.pop } }.sort
    refute LongformTranscript::Run.find(@run.id).work_remaining?, "duplicate jobs must not spin while a batch owns claims"

    gates[1] << true
    assert_equal 1, Timeout.timeout(5) { saved.pop }
    assert_equal %w[processing completed pending], @run.chunks.pluck(:status)
    assert_empty @run.turns
    assert @run.audio_path.file?
    gates[0] << true
    Timeout.timeout(5) { worker.value }
    assert_equal 0, saved.pop

    resumed = LongformTranscript::Run.find(@run.id)
    calls = []
    install_transcriber(resumed) { |chunk| calls << chunk.number }
    resumed.process_next_batch!(limit: 2)
    assert_equal [ 2 ], calls
    assert_transcript
  end

  test "a failed chunk retries without repeating successful siblings" do
    calls = Queue.new
    install_transcriber(@run) do |chunk|
      calls << chunk.number
      raise LongformTranscript::Transcriber::InvalidOutput.new("missing_speaker", 0) if chunk.number == 1
    end
    @run.process_next_batch!(limit: 3)
    assert_equal %w[completed failed completed], @run.chunks.pluck(:status)
    assert @run.audio_path.file?
    assert_empty @run.turns

    resumed = LongformTranscript::Run.find(@run.id)
    install_transcriber(resumed) { |chunk| calls << chunk.number }
    resumed.process_next_batch!(limit: 3)
    assert_equal({ 0 => 1, 1 => 2, 2 => 1 }, 4.times.map { calls.pop }.tally)
    assert_transcript
  end

  test "an expired worker's late success cannot replace the reclaimed result" do
    assert_expired_worker_ignored
  end

  test "an expired worker's late failure cannot fail the reclaimed result or remove audio" do
    assert_expired_worker_ignored(error: LongformTranscript::Run::ExternalFailure.new("ffmpeg_failed", retryable: false))
  end

  test "a late failure is ignored even while the reclaimed attempt is still processing" do
    assert_expired_worker_ignored(error: LongformTranscript::Run::ExternalFailure.new("ffmpeg_failed", retryable: false),
      while_processing: true)
  end

  test "a late success is ignored even while the reclaimed attempt is still processing" do
    assert_expired_worker_ignored(while_processing: true)
  end

  test "a programming error stays visible while successful sibling results survive for restart" do
    install_transcriber(@run) { |chunk| raise NoMethodError, "provider integration bug" if chunk.number == 1 }
    assert_raises(NoMethodError) { @run.process_next_batch!(limit: 3) }
    assert_equal %w[completed processing completed], @run.chunks.pluck(:status)
    @run.chunks.second.update!(claimed_at: 31.minutes.ago)
    install_transcriber(@run)

    @run.process_next_batch!(limit: 3)

    assert_equal [ 1, 2, 1 ], @run.chunks.pluck(:retry_count)
    assert_transcript
  end

  test "resuming a legacy run preserves already stabilized chunk outputs" do
    install_transcriber(@run)
    first, second = @run.chunks.first(2)
    [ first, second ].each do |chunk|
      result, latency = @run.send(:transcribe_chunk, chunk)
      turns = result.turns
      words = result.words
      if chunk.number == 1
        turns.each { |turn| turn["speaker_id"] = "speaker_2" }
        words.each { |word| word["speaker_id"] = "speaker_2" }
      end
      chunk.update!(status: "completed", retry_count: 1, output: { "turns" => turns, "words" => words },
        input_tokens: result.response.tokens.input, output_tokens: result.response.tokens.output,
        reported_cost_usd: result.response.tokens.reported_cost, latency_ms: latency)
    end
    saved = [ first.output.deep_dup, second.output.deep_dup ]
    calls = []
    install_transcriber(@run) { |chunk| calls << chunk.number }

    @run.process_next_batch!(limit: 3)

    assert_equal [ 2 ], calls
    assert_equal saved, [ first.reload.output, second.reload.output ]
    assert_transcript
  end

  test "concurrent finalizers preserve one set of turns and stable speaker IDs" do
    install_transcriber(@run)
    @run.define_singleton_method(:finalize_if_complete!) { raise "interrupted before assembly" }
    assert_raises(RuntimeError) { @run.process_next_batch!(limit: 3) }
    assert_equal %w[completed completed completed], @run.chunks.pluck(:status)
    gate = new_gate
    workers = 2.times.map do
      start_worker do
        gate.pop
        run = LongformTranscript::Run.find(@run.id)
        run.send(:finalize_if_complete!)
        run.turns.pluck(:id)
      end
    end
    2.times { gate << true }
    ids = workers.map { |worker| Timeout.timeout(5) { worker.value } }
    assert_equal ids.first, ids.last
    assert_transcript
  end

  test "a terminal failure keeps audio until its in-flight sibling finishes" do
    entered = Queue.new
    gate = new_gate
    saved = Queue.new
    install_transcriber(@run) do |chunk|
      entered << chunk.number
      if chunk.number.zero?
        raise LongformTranscript::Run::ExternalFailure.new("ffmpeg_failed", retryable: false)
      end
      Timeout.timeout(5) { gate.pop }
    end
    @run.define_singleton_method(:fail_chunk!) do |*args, **kwargs|
      super(*args, **kwargs)
      saved << true
    end
    worker = start_worker { @run.process_next_batch!(limit: 2) }
    2.times { Timeout.timeout(5) { entered.pop } }
    Timeout.timeout(5) { saved.pop }
    assert @run.audio_path.file?
    gate << true
    Timeout.timeout(5) { worker.value }
    assert_equal "failed", @run.reload.status
    refute @run.work_remaining?
    refute @run.audio_path.exist?
    assert_equal %w[failed completed pending], @run.chunks.pluck(:status)
  end

  test "batch limits must be positive integers" do
    [ 0, -1, 1.5, nil ].each do |limit|
      assert_raises(ArgumentError) { @run.process_next_batch!(limit: limit) }
    end
    assert_equal [ 0, 0, 0 ], @run.chunks.pluck(:retry_count)
  end

  test "words with a speaker missing from turns fail the chunk before deferred reconciliation" do
    install_transcriber(@run)
    transcribe = @run.method(:transcribe_chunk)
    @run.singleton_class.remove_method(:transcribe_chunk)
    @run.define_singleton_method(:transcribe_chunk) do |chunk|
      result, latency = transcribe.call(chunk)
      [ LongformTranscript::Transcriber::Result.new(result.response, result.turns.first(1), result.words), latency ]
    end

    @run.process_next_batch!(limit: 1)

    assert_equal %w[failed pending pending], @run.chunks.pluck(:status)
    assert_equal "invalid_structured_output", @run.chunks.first.failure_code
    assert @run.work_remaining?
    install_transcriber(@run)
    @run.process_next_batch!(limit: 3)
    assert_transcript
  end

  test "provider threads run inside the Rails executor" do
    observed = Queue.new
    install_transcriber(@run) { observed << Rails.application.executor.active? }
    Rails.application.executor.wrap { @run.process_next_batch!(limit: 3) }

    assert_equal [ true, true, true ], 3.times.map { observed.pop }
    assert_transcript
  end

  private

  def install_transcriber(run, &before_response)
    responses = @fixture.fetch("responses")
    run.singleton_class.remove_method(:transcribe_chunk) if run.singleton_methods.include?(:transcribe_chunk)
    run.define_singleton_method(:transcribe_chunk) do |chunk|
      before_response&.call(chunk)
      payload = responses.fetch(chunk.number)
      usage = payload.fetch("usage")
      response = Response.new(payload.fetch("segments"), payload.fetch("words"), model,
        RubyLLM::Tokens.new(input: usage.fetch("input_tokens"), output: usage.fetch("output_tokens"),
          reported_cost: BigDecimal(usage.fetch("cost").to_s)))
      turns, words = LongformTranscript::Transcriber.new(model: model, profile: profile)
        .send(:normalize_transcription, response, chunk)
      [ LongformTranscript::Transcriber::Result.new(response, turns, words), 10 + chunk.number ]
    end
  end

  def new_gate
    Queue.new.tap { |gate| @gates << gate }
  end

  def start_worker(&block)
    Thread.new { ActiveRecord::Base.connection_pool.with_connection(&block) }.tap { |worker| @workers << worker }
  end

  def assert_expired_worker_ignored(error: nil, while_processing: false)
    entered = Queue.new
    gate = new_gate
    install_transcriber(@run) do
      entered << true
      Timeout.timeout(5) { gate.pop }
      raise error if error
    end
    worker = start_worker { @run.process_next_batch!(limit: 1) }
    Timeout.timeout(5) { entered.pop }
    @run.chunks.first.update!(claimed_at: 31.minutes.ago)
    resumed = LongformTranscript::Run.find(@run.id)
    reclaimed_gate = new_gate
    install_transcriber(resumed) do
      entered << true
      Timeout.timeout(5) { reclaimed_gate.pop }
    end
    replacement = start_worker { resumed.process_next_batch!(limit: 1) }
    Timeout.timeout(5) { entered.pop }
    unless while_processing
      reclaimed_gate << true
      Timeout.timeout(5) { replacement.value }
    end
    completed = resumed.chunks.first.attributes
    assert_equal 2, completed.fetch("retry_count")

    gate << true
    Timeout.timeout(5) { worker.value }
    assert_equal completed, resumed.chunks.first.reload.attributes
    assert_equal "processing", resumed.reload.status
    assert resumed.audio_path.file?
    if while_processing
      reclaimed_gate << true
      Timeout.timeout(5) { replacement.value }
    end
    install_transcriber(resumed)
    resumed.process_next_batch!(limit: 2)
    assert_transcript
  end

  def assert_transcript
    assert_equal "completed", @run.reload.status
    assert_equal @fixture.fetch("expected_turns"), @run.turns.pluck(:position, :start_ms, :end_ms, :speaker_id, :text)
    assert_equal 53, @run.input_tokens
    assert_equal 37, @run.output_tokens
    assert_equal BigDecimal("0.007"), @run.reported_cost_usd
    assert_equal 33, @run.total_latency_ms
    assert @run.chunks.all? { |chunk| !chunk.output.key?("speaker_scope") }
    refute @run.audio_path.exist?
  end
end
