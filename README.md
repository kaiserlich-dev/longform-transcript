# LongformTranscript

A Rails engine for durable, resumable speaker transcription with RubyLLM 2.x and ffmpeg.

## Installation

Add `gem "longform_transcript"`, then run:

```sh
bin/rails generate longform_transcript:install
bin/rails db:migrate
```

The host must provide `ffmpeg`/`ffprobe` and configure RubyLLM credentials. Configuration is optional:

```ruby
LongformTranscript.configure do |config|
  config.storage_root = Rails.root.join("data/transcripts")
  config.queue_name = :transcripts
  config.chunk_duration = 5.minutes
  config.chunk_overlap = 5.seconds
  config.download_limit = 1.gigabyte
  config.stale_after = 30.minutes
  config.publication_callback = ->(run) { TranscriptPublishedJob.perform_later(run.id) }
end
```

## API

```ruby
profile = {
  version: "de-v1",
  interface: :transcription,
  provider_options: { "sort" => "latency" }
}
run = LongformTranscript.prepare_for!(podcast,
  source_audio_url: podcast.audio_url, model: "openai/gpt-4o-mini-transcribe", profile: profile)

LongformTranscript::ProcessJob.perform_later(run.id) # one chunk per job; continues itself
run.process_next_chunk!                              # synchronous one-chunk processing
run.release_stale_chunks!
run.retry_invalid_output!
run.publish!("speaker_1" => "Host", "speaker_2" => "Guest")
```

`prepare_for!` is idempotent for a transcribable, canonical URL identity, model, profile version, and schema version.
Profiles are ordinary hashes and are persisted on each run so resumed jobs retain provider settings. Publication atomically
replaces the previously published run for the polymorphic transcribable and invokes the optional callback afterward.
