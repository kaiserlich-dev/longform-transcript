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
  version: "speaker-transcript-v1",
  interface: :transcription,
  language: "en",
  provider_options: { "sort" => "latency" }
}
run = LongformTranscript.prepare_for!(recording,
  source_audio_url: recording.audio_url, model: "openai/gpt-4o-mini-transcribe", profile: profile)

LongformTranscript::ProcessJob.perform_later(run.id) # one chunk per job; continues itself
run.process_next_chunk!                              # synchronous one-chunk processing
run.release_stale_chunks!
run.retry_invalid_output!
run.publish!("speaker_1" => "Host", "speaker_2" => "Guest")
```

`prepare_for!` is idempotent for a transcribable, canonical URL identity, model, profile version, and schema version.
Profiles are ordinary hashes and are persisted on each run so resumed jobs retain provider settings. Publication atomically
replaces the previously published run for the polymorphic transcribable and invokes the optional callback afterward.

## Regression checks

Use the Ruby version in `.ruby-version`, Bundler, and ffmpeg/ffprobe. In an Amp orb, run `.agents/setup` first.

```sh
bundle install
bundle exec rake test
bundle exec rubocop
# Only the multi-chunk pipeline replay:
bundle exec ruby -Itest test/jobs/transcription_replay_test.rb
```

The suite uses a disposable SQLite database in the system temporary directory. Do not run separate test processes
simultaneously: they share that database. CI runs the full suite and lint on pushes and pull requests.

`test/fixtures/transcription/three_chunks.json` contains **hand-authored, synthetic** OpenRouter-format responses,
not recordings from a real episode. The replay generates local tone audio and runs real ffmpeg clipping, RubyLLM
response parsing, speaker reconciliation, persistence, assembly, and job continuation; HTTP is stubbed and needs
no credentials. Its independently specified expected turns cover changing local speaker IDs, a returning speaker,
and words duplicated across overlaps. Four-second cores with one-second overlaps make the example small enough to
audit by hand. Tests also exercise retry isolation, restart after saving a chunk, and an overlapping duplicate worker.

For behavior-preserving optimizations, keep the expected transcript unchanged: text, speaker IDs, timestamps, and
ordering must match exactly. Boundary tests protect the inclusive 250 ms speaker-match tolerance and half-open
chunk cores; cache tests reject content corruption even when size and modification time match.

This is a compatibility safety net, not a speech-quality benchmark or proof of parallel-processing safety. Before
introducing parallel chunks, add out-of-order completion, expired-worker success/failure, and simultaneous-finalization
tests for that design. Before changing models, chunk sizes, or audio encoding, add permission-cleared real episode
recordings/responses and reviewed transcripts, and measure quality as well as runtime. Do not regenerate expected
outputs merely to make a refactor pass.
