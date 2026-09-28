require "test_helper"

class LongformTranscriptProcessJobTest < ActiveJob::TestCase
  MODEL = "openai/gpt-4o-mini-transcribe"
  PROVIDER_OPTIONS = {
    "sort" => "latency",
    "options" => { "azure" => { "diarization" => { "enabled" => true },
      "phraseList" => { "phrases" => [ "Alice", "Bob" ] } } }
  }.freeze
  FakeTranscription = Data.define(
    :text, :segments, :words, :model, :tokens
  )

  test "uses the transcript queue for bounded parallel processing" do
    assert_equal "transcripts", LongformTranscript::ProcessJob.new.queue_name
  end

  test "schedules one continuation only while work remains" do
    run = prepared_run
    klass = LongformTranscript::Run
    klass.alias_method(:original_process_next_chunk_for_test, :process_next_chunk!)
    klass.alias_method(:original_work_remaining_for_test, :work_remaining?)
    klass.remove_method(:process_next_chunk!)
    klass.remove_method(:work_remaining?)
    klass.define_method(:process_next_chunk!) { update!(failure_code: "processed") }
    klass.define_method(:work_remaining?) { true }

    assert_enqueued_with(job: LongformTranscript::ProcessJob, args: [ run.id ]) do
      LongformTranscript::ProcessJob.perform_now(run.id)
    end
    assert_equal "processed", run.reload.failure_code
  ensure
    if klass&.method_defined?(:original_process_next_chunk_for_test)
      klass.remove_method(:process_next_chunk!)
      klass.remove_method(:work_remaining?)
      klass.alias_method(:process_next_chunk!, :original_process_next_chunk_for_test)
      klass.alias_method(:work_remaining?, :original_work_remaining_for_test)
      klass.remove_method(:original_process_next_chunk_for_test)
      klass.remove_method(:original_work_remaining_for_test)
    end
  end

  test "processes one local chunk through RubyLLM OpenRouter and persists aggregate metadata" do
    document = Document.create!(title: "Job pilot")
    run = LongformTranscript.prepare_for!(document, source_audio_url: "https://audio.example/job.mp3",
      model: MODEL, profile: profile.merge(provider_options: PROVIDER_OPTIONS))
    FileUtils.mkdir_p(run.audio_path.dirname)
    system("ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=1",
      "-ac", "1", "-ar", "16000", run.audio_path.to_s, exception: true)
    duration = run.send(:probe_duration_ms, run.audio_path)
    digest = Digest::SHA256.file(run.audio_path).hexdigest
    run.update!(source_audio_sha256: digest, audio_duration_ms: duration, status: "processing")
    run.send(:prepare_chunks!, digest, duration)
    provider_arguments = nil
    transcription = FakeTranscription.new(
      "Test",
      [ { "speaker" => 0, "start" => 0.1, "end" => 0.5, "text" => "Test" } ],
      [ { "speaker" => 0, "start" => 0.1, "end" => 0.5, "word" => "Test" } ],
      MODEL,
      RubyLLM::Tokens.new(input: 12, output: 8, reported_cost: BigDecimal("0.0012"))
    )
    transcribe = ->(path, **arguments) {
      raise "missing generated clip" unless File.file?(path)

      provider_arguments = arguments
      transcription
    }
    RubyLLM.singleton_class.alias_method(:original_transcribe_for_test, :transcribe)
    RubyLLM.singleton_class.remove_method(:transcribe)
    RubyLLM.define_singleton_method(:transcribe, transcribe)
    assert_no_enqueued_jobs { LongformTranscript::ProcessJob.perform_now(run.id) }

    assert_equal :openrouter, provider_arguments.fetch(:provider)
    assert_equal MODEL, provider_arguments.fetch(:model)
    assert_equal "en", provider_arguments.fetch(:language)
    assert_equal "verbose_json", provider_arguments.fetch(:format)
    assert_equal [ :segment, :word ], provider_arguments.fetch(:timestamps)
    assert_equal({ provider: PROVIDER_OPTIONS.deep_symbolize_keys },
      provider_arguments.fetch(:provider_options))
    assert_equal "completed", run.reload.status
    assert_equal [ "Test" ], run.turns.pluck(:text)
    assert_equal [ 100 ], run.turns.pluck(:start_ms)
    assert_equal [ "Test" ], run.chunks.sole.output.fetch("words").pluck("text")
    assert_equal 12, run.input_tokens
    assert_equal 8, run.output_tokens
    assert_equal BigDecimal("0.0012"), run.reported_cost_usd
    refute run.audio_path.exist?, "completed runs must clean up cached source audio"
  ensure
    if RubyLLM.singleton_class.method_defined?(:original_transcribe_for_test)
      RubyLLM.singleton_class.remove_method(:transcribe)
      RubyLLM.singleton_class.alias_method(:transcribe, :original_transcribe_for_test)
      RubyLLM.singleton_class.remove_method(:original_transcribe_for_test)
    end
    FileUtils.rm_rf(run&.audio_path&.dirname)
  end

  test "OpenRouter transport sends timestamps and Azure diarization in the provider envelope" do
    request_payload = nil
    stub_request(:post, "https://openrouter.ai/api/v1/audio/transcriptions")
      .with { |request| request_payload = JSON.parse(request.body); true }
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          text: "Guten Morgen", segments: [ { speaker: 0, start: 0.0, end: 0.5, text: "Guten Morgen" } ],
          words: [ { speaker: 0, start: 0.0, end: 0.5, word: "Guten Morgen" } ],
          usage: { input_tokens: 2, output_tokens: 2, cost: 0.001 }
        }.to_json
      )
    config = RubyLLM.config.dup
    config.openrouter_api_key = "test"
    model, provider = RubyLLM::Models.resolve(
      MODEL, provider: :openrouter, config: config
    )

    Tempfile.create([ "transcription", ".mp3" ]) do |audio|
      audio.binmode
      audio.write("audio")
      audio.flush
      transcription = provider.transcribe(
        audio.path,
        model: model,
        language: "en",
        format: "verbose_json",
        timestamps: [ :segment, :word ],
        provider_options: { provider: PROVIDER_OPTIONS }
      )

      assert_equal "verbose_json", request_payload.fetch("response_format")
      assert_equal %w[segment word], request_payload.fetch("timestamp_granularities")
      assert request_payload.dig("provider", "options", "azure", "diarization", "enabled")
      assert_equal [ "Alice", "Bob" ],
        request_payload.dig("provider", "options", "azure", "phraseList", "phrases")
      assert_equal 0, transcription.words.sole.fetch("speaker")
      assert_equal BigDecimal("0.001"), transcription.tokens.reported_cost
    end
  end
end
