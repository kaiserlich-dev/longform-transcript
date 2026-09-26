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

### Align transcript sections

`align_sections` splits already-grouped passages at ordered section boundaries. It fuzzy-matches lightly edited section
text, uses exact word timestamps when available, and falls back to turn or proportional timings. Sections can be any Ruby
objects; the required block supplies their source transcript text, and the same objects are returned in `:sections`:

```ruby
passages = run.turns.to_a.chunk_while { |left, right| left.speaker_id == right.speaker_id }.to_a
words = sorted_word_timings_for(run) # host-owned overlap filtering/deduplication

fragments = LongformTranscript.align_sections(
  sections: episode.chapters.to_a,
  passages: passages,
  words: words,
  &:content
)

fragments.each do |fragment|
  fragment.fetch(:sections)   # section objects beginning at this fragment
  fragment.fetch(:first_turn) # original first turn
  fragment.fetch(:last_turn)  # original last turn
  fragment.fetch(:text)
  fragment.fetch(:words)      # matched word hashes, or []
  fragment.fetch(:start_ms)
  fragment.fetch(:end_ms)
end
```

Passages must contain turn-like objects responding to `text`, `start_ms`, and `end_ms`. Word hashes use the transcript
output keys `"text"`, `"start_ms"`, and `"end_ms"` and must be sorted by time. Grouping speakers, selecting words from
overlapping chunks, caching, presentation, and converting application chapter models remain host-application concerns.
