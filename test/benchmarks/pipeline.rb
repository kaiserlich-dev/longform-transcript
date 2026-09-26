# Run with: bundle exec ruby -Itest test/benchmarks/pipeline.rb
# Synthetic provider latency, real clipping/parsing/persistence. No paid API requests.
require "test_helper"
include WebMock::API

fixture = JSON.parse(File.read(File.expand_path("../fixtures/transcription/three_chunks.json", __dir__)))
LongformTranscript.chunk_duration = 4.seconds
LongformTranscript.chunk_overlap = 1.second
RubyLLM.config.openrouter_api_key = "test"
stub_request(:post, "https://openrouter.ai/api/v1/audio/transcriptions").to_return do
  sleep 0.5
  { status: 200, headers: { "Content-Type" => "application/json" },
    body: fixture.fetch("responses").fetch(Thread.current[:benchmark_chunk]).to_json }
end

[ 1, 2, 3 ].each do |limit|
  samples = 3.times.map do
    run = LongformTranscript.prepare_for!(Document.create!(title: "Benchmark"),
      source_audio_url: "https://audio.example/benchmark.mp3", model: "openai/gpt-4o-mini-transcribe",
      profile: { version: "benchmark", interface: :transcription, provider: :openrouter, language: "en" })
    FileUtils.mkdir_p(run.audio_path.dirname)
    system("ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=11",
      "-ac", "1", "-ar", "16000", run.audio_path.to_s, exception: true)
    run.update!(source_audio_sha256: Digest::SHA256.file(run.audio_path).hexdigest, audio_duration_ms: 11_000,
      status: "processing")
    run.send(:prepare_chunks!, run.source_audio_sha256, run.audio_duration_ms)
    run.define_singleton_method(:transcribe_chunk) do |chunk|
      Thread.current[:benchmark_chunk] = chunk.number
      super(chunk)
    ensure
      Thread.current[:benchmark_chunk] = nil
    end
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    run.process_next_batch!(limit: limit) until run.reload.status == "completed"
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    actual = run.turns.pluck(:position, :start_ms, :end_ms, :speaker_id, :text)
    raise "transcript changed" unless actual == fixture.fetch("expected_turns")

    elapsed
  end
  puts "concurrency=#{limit}, three chunks, 500ms stubbed provider latency: median #{samples.sort[1].round(3)}s"
end
