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
  config.chunk_concurrency = 2
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

LongformTranscript::ProcessJob.perform_later(run.id) # bounded batch per job; continues itself
run.process_next_chunk!                              # synchronous one-chunk processing, as before
run.process_next_batch!(limit: 2)                    # waits for up to two concurrent requests
run.release_stale_chunks!
run.retry_invalid_output!
run.publish!("speaker_1" => "Host", "speaker_2" => "Guest")
```

`prepare_for!` is idempotent for a transcribable, canonical URL identity, model, profile version, and schema version.
Profiles are ordinary hashes and are persisted on each run so resumed jobs retain provider settings. Publication atomically
replaces the previously published run for the polymorphic transcribable and invokes the optional callback afterward.

## Performance and concurrency

Jobs process up to `chunk_concurrency` chunks at once (default **2**). Set it to **1** to restore sequential requests.
Clipping and provider calls run in Rails Executor-wrapped threads; the job thread saves each result as it arrives.
Speaker reconciliation runs in chunk order after all chunks finish, so completion order does not change the final
transcript. Successful chunks survive interrupted jobs and retries. Duplicate workers cannot claim a second live
batch, and expired attempts cannot overwrite a replacement attempt's success or failure.

Concurrency is per job, not an account-wide rate limiter: four job workers with concurrency 2 can issue eight provider
requests and run eight ffmpeg processes. Size worker capacity for provider quotas, CPU and memory; start at 1 if
the provider has restrictive quotas. Requests use separate RubyLLM clients and clip files. Keep RubyLLM configuration
and its model registry unchanged while requests run, and use thread-safe custom loggers/instrumenters.
Keep `storage_root` accessible to workers handling continuations to avoid repeated downloads. Checksums are still
verified once per batch. No model, audio encoding, chunk duration, or overlap changes are required for these gains.

Until assembly, new completed chunks have `output["speaker_scope"] == "local"`: their speaker IDs are chunk-local.
Use the completed run's turns for stable episode-wide IDs. Assembly atomically reconciles those outputs and removes
the marker. Older saved chunks without the marker are already stable and remain unchanged. No database migration
is required. **Drain old workers before upgrading; do not mix old and new workers.** For rollback, set concurrency
to 1 on the new code; finish runs containing local-scope outputs before downgrading to old code.

Phase logs include `audio_cache_check`, `clip`, `provider`, `speaker_reconciliation`, and `assembly` alongside download
phases. `total_latency_ms` remains the sum of successful provider durations, **not** episode wall time; it can exceed
elapsed time with parallel requests. Measure queue delay and end-to-end wall time separately.

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

Batch tests force out-of-order completion, late success/failure from expired workers, simultaneous finalization,
partial failure, and restart with legacy outputs. Speaker matching is also compared with exhaustive matching over
100 seeded generated cases. These are compatibility checks, not a speech-quality benchmark. Before changing models,
chunk sizes, or audio encoding, add permission-cleared real recordings/responses and reviewed transcripts, and measure
quality as well as runtime. Do not regenerate expected outputs merely to make a refactor pass.

Reproducible local benchmarks (same disposable database; run one at a time):

```sh
bundle exec ruby -Itest test/benchmarks/speakers.rb
bundle exec ruby -Itest test/benchmarks/pipeline.rb
```

The speaker benchmark compares 1,200 previous and 1,200 current words with independently checked speaker IDs.
The pipeline benchmark checks the exact replay transcript with real clipping and **simulated 500 ms API latency**, at
concurrency 1, 2, and 3. It excludes source download and queue delay; it is not a live-provider speed or quality claim.
