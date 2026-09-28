require "test_helper"

class LongformTranscriptRunTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  FakeTranscription = Data.define(:segments, :words)
  FakeMultimodalResponse = Data.define(:content, :model_id)

  setup do
    @document = Document.create!(title: "Pilot")
    @run = LongformTranscript.prepare_for!(@document,
      source_audio_url: "https://audio.example/document.mp3?token=first",
      model: "openai/test-transcribe", profile: profile)
  end

  teardown do
    FileUtils.rm_rf(@run.audio_path.dirname) if @run&.persisted?
  end

  test "versioned source identity reuses a run and refreshes a non-identity query string" do
    original_identity = @run.source_audio_identity
    resumed = LongformTranscript.prepare_for!(@document,
      source_audio_url: "https://audio.example/document.mp3?token=second#ignored",
      model: @run.model, profile: profile)

    assert_equal @run, resumed
    assert_equal original_identity, resumed.source_audio_identity
    assert_equal "https://audio.example/document.mp3?token=second", resumed.source_audio_url

    changed_version = @document.transcript_runs.create!(
      source_audio_url: resumed.source_audio_url, source_audio_identity: original_identity,
      model: resumed.model, profile: profile, prompt_version: "speaker-transcript-de-v3",
      schema_version: resumed.schema_version
    )
    assert_not_equal resumed, changed_version
  end

  test "deterministic chunks use bounded overlap and the audio digest" do
    @run.update!(source_audio_sha256: "a" * 64, audio_duration_ms: 1_205_000, status: "processing")
    @run.send(:prepare_chunks!, @run.source_audio_sha256, @run.audio_duration_ms)
    @run.send(:prepare_chunks!, @run.source_audio_sha256, @run.audio_duration_ms)

    assert_equal 4, @run.chunks.count
    assert_equal [
      [ 0, 0, 305_000 ], [ 1, 295_000, 605_000 ], [ 2, 595_000, 905_000 ],
      [ 3, 895_000, 1_205_000 ]
    ], @run.chunks.pluck(:number, :start_ms, :end_ms)
    assert_equal [ "a" * 64 ], @run.chunks.distinct.pluck(:source_digest)
  end

  test "does not create a trailing chunk already covered by overlap" do
    prepare_chunks(duration_ms: 600_842)

    assert_equal [
      [ 0, 0, 305_000 ], [ 1, 295_000, 600_842 ]
    ], @run.chunks.pluck(:number, :start_ms, :end_ms)
  end

  test "claims are atomic, ordered, resumable, and bounded" do
    prepare_chunks(duration_ms: 1_205_000)
    first = @run.send(:claim_next_chunk!)

    assert_equal 0, first.number
    assert_nil @run.send(:claim_next_chunk!), "a second worker must not pass an active claim"

    first.update!(claimed_at: 31.minutes.ago)
    reclaimed = @run.send(:claim_next_chunk!)
    assert_equal first, reclaimed
    assert_equal 2, reclaimed.retry_count
    assert_equal "processing", reclaimed.status

    reclaimed.update!(status: "failed", retryable: true, retry_count: 3, failure_code: "provider_transient")
    assert_nil @run.send(:claim_next_chunk!)
    assert_equal "failed", @run.reload.status
    assert_equal "pending", @run.chunks.find_by!(number: 1).status
    refute @run.work_remaining?, "an exhausted first chunk must not create a no-op job loop"
  end

  test "a deployment restart reuses persistent audio and resumes after completed chunks" do
    FileUtils.mkdir_p(@run.audio_path.dirname)
    File.binwrite(@run.audio_path, "persistent audio")
    digest = Digest::SHA256.file(@run.audio_path).hexdigest
    @run.update!(source_audio_sha256: digest, audio_duration_ms: 600_000, status: "processing")
    @run.send(:prepare_chunks!, digest, @run.audio_duration_ms)
    first = @run.chunks.ordered.first
    first.update!(status: "completed", retry_count: 1, output: { "turns" => [], "words" => [] })

    resumed = LongformTranscript::Run.find(@run.id)
    resumed.define_singleton_method(:download_audio!) { flunk("persistent audio must be reused after restart") }

    assert resumed.send(:ensure_audio!)
    assert_equal 1, resumed.send(:claim_next_chunk!).number
    assert_equal [ "completed", 1 ], first.reload.attributes.values_at("status", "retry_count")
  end

  test "database constraints reject illegal durable states" do
    assert_raises(ActiveRecord::StatementInvalid) { @run.update_column(:status, "unknown") }
    chunk = prepare_chunks(duration_ms: 1_000).first
    assert_raises(ActiveRecord::StatementInvalid) { chunk.update_column(:retry_count, 4) }
  end

  test "invalid structured output remains retryable within the bounded claim limit" do
    chunk = prepare_chunks(duration_ms: 1_000).first
    chunk.update!(status: "processing", retry_count: 1, claimed_at: Time.current)

    @run.send(:fail_chunk!, chunk, "invalid_structured_output", retryable: true)

    assert_equal "failed", chunk.reload.status
    assert_predicate chunk, :retryable?
    assert @run.work_remaining?
  end

  test "an explicit invalid-output retry resets only exhausted invalid chunks" do
    first, second = prepare_chunks(duration_ms: 600_000)
    first.update!(status: "completed", retry_count: 1, output: { "turns" => [
      { "speaker_id" => "speaker_1", "start_ms" => 0, "end_ms" => 1_000, "text" => "Fertig" }
    ] })
    second.update!(status: "failed", retry_count: 3, retryable: true,
      failure_code: "invalid_structured_output", failed_at: Time.current)
    @run.update!(status: "failed", failure_code: "invalid_structured_output", failed_at: Time.current)

    @run.retry_invalid_output!

    assert_equal [ "completed", 1 ], first.reload.attributes.values_at("status", "retry_count")
    assert_equal [ "pending", 0, nil ], second.reload.attributes.values_at("status", "retry_count", "failure_code")
    assert_equal [ "processing", nil ], @run.reload.attributes.values_at("status", "failure_code")
  end

  test "an explicit invalid-output retry rejects unrelated failures" do
    chunk = prepare_chunks(duration_ms: 60_000).first
    chunk.update!(status: "failed", retry_count: 3, retryable: false, failure_code: "provider_permanent")
    @run.update!(status: "failed", failure_code: "provider_permanent", failed_at: Time.current)

    assert_raises(ArgumentError) { @run.retry_invalid_output! }
  end

  test "a fresh audio claim blocks duplicate preparation and a stale claim is recoverable" do
    @run.update!(status: "processing", audio_claimed_at: Time.current)
    @run.define_singleton_method(:download_audio!) { flunk("fresh claim must block another download") }
    assert_not @run.send(:ensure_audio!)

    @run.update!(audio_claimed_at: 31.minutes.ago)
    @run.singleton_class.remove_method(:download_audio!)
    @run.define_singleton_method(:download_audio!) { |path, *| File.binwrite(path, "fixture audio") }
    @run.define_singleton_method(:probe_duration_ms) { |_| 1_000 }
    assert @run.send(:ensure_audio!)
    assert_nil @run.reload.audio_claimed_at
    assert_equal 1, @run.chunks.count
  end

  test "transcription preserves real segment and word timestamps and normalizes speaker IDs" do
    chunk = prepare_chunks(duration_ms: 60_000).first
    response = FakeTranscription.new(
      [
        { "speaker" => "A", "start" => 0.25, "end" => 1.5, "text" => " Hallo " },
        { "speaker" => "B", "start" => 1.5, "end" => 2.75, "text" => "Welt" }
      ],
      [
        { "speaker" => "A", "start" => 0.25, "end" => 0.7, "word" => "Hallo" },
        { "speaker" => "B", "start" => 1.5, "end" => 2.1, "word" => "Welt" }
      ]
    )

    turns, words = @run.send(:validated_transcription, response, chunk)

    assert_equal [ 250, 1_500 ], turns.pluck("start_ms")
    assert_equal [ 1_500, 2_750 ], turns.pluck("end_ms")
    assert_equal %w[speaker_1 speaker_2], turns.pluck("speaker_id")
    assert_equal [ 250, 1_500 ], words.pluck("start_ms")
    assert_equal %w[speaker_1 speaker_2], words.pluck("speaker_id")
  end

  test "multimodal transcription preserves returned timestamps and normalizes speaker IDs" do
    chunk = prepare_chunks(duration_ms: 60_000).first
    response = FakeMultimodalResponse.new(
      { turns: [
        { speaker_id: "Gast", start_ms: 250, end_ms: 1_500, text: " Hallo " },
        { speaker_id: "Host", start_ms: 1_500, end_ms: 2_750, text: "Welt" }
      ] }, "google/gemini-3.8-flash"
    )

    turns = @run.send(:validated_multimodal_transcription, response, chunk)

    assert_equal [ 250, 1_500 ], turns.pluck("start_ms")
    assert_equal [ 1_500, 2_750 ], turns.pluck("end_ms")
    assert_equal %w[speaker_1 speaker_2], turns.pluck("speaker_id")
    assert_equal %w[Hallo Welt], turns.pluck("text")
    assert_equal "google/gemini-3.8-flash", @run.send(:response_model, response)
  end

  test "multimodal transcription rejects timestamps outside the supplied audio chunk" do
    chunk = prepare_chunks(duration_ms: 60_000).first
    response = FakeMultimodalResponse.new(
      { turns: [ { speaker_id: "Host", start_ms: 59_000, end_ms: 62_000, text: "Zu spät" } ] },
      "google/gemini-3.8-flash"
    )

    assert_raises(ArgumentError) { @run.send(:validated_multimodal_transcription, response, chunk) }
  end

  test "transcription falls back to diarized words when aggregate segments are missing or malformed" do
    chunk = prepare_chunks(duration_ms: 60_000).first
    words = [
      { "speaker" => "A", "start" => 0.1, "end" => 0.5, "word" => "Hallo" },
      { "speaker" => "B", "start" => 0.6, "end" => 1.0, "word" => "Welt" }
    ]

    [ [], nil, [ { "speaker" => "A", "start" => 2.0, "end" => 1.0, "text" => "Kaputt" } ] ].each do |segments|
      turns, = @run.send(:validated_transcription, FakeTranscription.new(segments, words), chunk)

      assert_equal %w[Hallo Welt], turns.pluck("text")
      assert_equal %w[speaker_1 speaker_2], turns.pluck("speaker_id")
    end
  end

  test "transcription rejects missing speakers and invalid word timestamps" do
    chunk = prepare_chunks(duration_ms: 60_000).first
    valid_segments = [ { "speaker" => "A", "start" => 0.1, "end" => 1.0, "text" => "Text" } ]

    invalid_responses = [
      FakeTranscription.new(valid_segments, [ { "speaker" => nil, "start" => 0.1, "end" => 0.5, "word" => "Text" } ]),
      FakeTranscription.new(valid_segments, [ { "speaker" => "A", "start" => 59.0, "end" => 62.0, "word" => "Text" } ])
    ]
    expected_reasons = %w[missing_speaker out_of_range]
    invalid_responses.zip(expected_reasons).each do |response, reason|
      error = assert_raises(LongformTranscript::Run::InvalidTranscription) do
        @run.send(:validated_transcription, response, chunk)
      end
      assert_equal reason, error.reason
      assert_kind_of Integer, error.item_index
    end
  end

  test "transcription stable-sorts valid provider words by timestamp" do
    chunk = prepare_chunks(duration_ms: 60_000).first
    response = FakeTranscription.new([], [
      { "speaker" => "A", "start" => 0.5, "end" => 0.8, "word" => "später" },
      { "speaker" => "A", "start" => 0.1, "end" => 0.4, "word" => "früher" }
    ])

    turns, words = @run.send(:validated_transcription, response, chunk)

    assert_equal [ "früher", "später" ], words.pluck("text")
    assert_equal [ 100, 500 ], words.pluck("start_ms")
    assert_equal [ "früher später" ], turns.pluck("text")
  end

  test "transcription derives turns from diarized words when aggregate segments have no speaker" do
    chunk = prepare_chunks(duration_ms: 60_000).first
    response = FakeTranscription.new(
      [ { "start" => 0, "end" => 2, "text" => "Hallo Welt" } ],
      [
        { "speaker" => 0, "start" => 0.1, "end" => 0.5, "word" => "Hallo" },
        { "speaker" => 1, "start" => 1.0, "end" => 1.5, "word" => "Welt" }
      ]
    )

    turns, = @run.send(:validated_transcription, response, chunk)

    assert_equal %w[speaker_1 speaker_2], turns.pluck("speaker_id")
    assert_equal [ 100, 1_000 ], turns.pluck("start_ms")
    assert_equal %w[Hallo Welt], turns.pluck("text")
  end

  test "overlap reconciliation keeps stable neutral speakers and assembles without duplicate turns" do
    first, second = prepare_chunks(duration_ms: 600_000)
    first.update!(status: "completed", output: { "turns" => [
      { "speaker_id" => "speaker_1", "start_ms" => 290_000, "end_ms" => 297_000, "text" => "Gleicher Übergang" },
      { "speaker_id" => "speaker_2", "start_ms" => 297_000, "end_ms" => 299_000, "text" => "Antwort" }
    ] })
    incoming = [
      { "speaker_id" => "speaker_2", "start_ms" => 290_000, "end_ms" => 297_000, "text" => "Gleicher Übergang" },
      { "speaker_id" => "speaker_1", "start_ms" => 301_000, "end_ms" => 305_000, "text" => "Neuer Satz" }
    ]

    stable = @run.send(:stabilize_speakers, incoming, second)
    assert_equal "speaker_1", stable.first.fetch("speaker_id")
    assert_equal "speaker_2", stable.second.fetch("speaker_id")
    second.update!(status: "completed", output: { "turns" => stable })

    assert @run.send(:finalize_if_complete!)
    assert @run.send(:finalize_if_complete!)
    assert_equal [ "Gleicher Übergang", "Antwort", "Neuer Satz" ], @run.turns.pluck(:text)
    assert_equal [ first.id, first.id, second.id ], @run.turns.pluck(:chunk_id)
  end

  test "speaker reconciliation tolerates small wording differences in the overlap" do
    first, second = prepare_chunks(duration_ms: 600_000)
    first.update!(status: "completed", output: { "turns" => [
      { "speaker_id" => "speaker_1", "start_ms" => 280_000, "end_ms" => 299_000,
        "text" => "Wir steigern die Belastung langsam und kontrolliert über mehrere Wochen." }
    ] })
    incoming = [
      { "speaker_id" => "speaker_2", "start_ms" => 295_000, "end_ms" => 310_000,
        "text" => "Wir steigern diese Belastung langsam und sehr kontrolliert über mehrere Wochen." }
    ]

    assert_equal "speaker_1", @run.send(:stabilize_speakers, incoming, second).sole.fetch("speaker_id")
  end

  test "word timestamps preserve a speaker across chunks when segment boundaries change" do
    first, second = prepare_chunks(duration_ms: 600_000)
    first.update!(status: "completed", output: {
      "turns" => [ { "speaker_id" => "speaker_2", "start_ms" => 280_000, "end_ms" => 305_000,
        "text" => "Ein langer Beitrag endet anders als der nächste Abschnitt beginnt." } ],
      "words" => [
        { "speaker_id" => "speaker_2", "start_ms" => 298_000, "end_ms" => 298_300, "text" => "gleiche" },
        { "speaker_id" => "speaker_2", "start_ms" => 298_400, "end_ms" => 298_700, "text" => "Stimme" }
      ]
    })
    incoming = [ { "speaker_id" => "speaker_1", "start_ms" => 295_000, "end_ms" => 330_000,
      "text" => "Der neue Abschnitt enthält sehr viel weiteren Text." } ]
    words = [
      { "speaker_id" => "speaker_1", "start_ms" => 298_040, "end_ms" => 298_340, "text" => "gleiche" },
      { "speaker_id" => "speaker_1", "start_ms" => 298_440, "end_ms" => 298_740, "text" => "Stimme" }
    ]

    assert_equal "speaker_2", @run.send(:stabilize_speakers, incoming, second, words).sole.fetch("speaker_id")
  end

  test "speaker reconciliation remembers a speaker absent from the previous chunk" do
    first, second, third = prepare_chunks(duration_ms: 900_000)
    first.update!(status: "completed", output: { "turns" => [
      { "speaker_id" => "speaker_1", "start_ms" => 0, "end_ms" => 100_000, "text" => "Erste Stimme" },
      { "speaker_id" => "speaker_2", "start_ms" => 100_000, "end_ms" => 300_000, "text" => "Zweite Stimme" }
    ] })
    second.update!(status: "completed", output: {
      "turns" => [
        { "speaker_id" => "speaker_2", "start_ms" => 300_000, "end_ms" => 600_000, "text" => "Nur zweite Stimme" }
      ],
      "words" => [
        { "speaker_id" => "speaker_2", "start_ms" => 598_000, "end_ms" => 598_300, "text" => "zweite" },
        { "speaker_id" => "speaker_2", "start_ms" => 598_400, "end_ms" => 598_700, "text" => "Stimme" }
      ]
    })
    incoming = [
      { "speaker_id" => "local_a", "start_ms" => 600_000, "end_ms" => 700_000, "text" => "Weiter zweite Stimme" },
      { "speaker_id" => "local_b", "start_ms" => 700_000, "end_ms" => 800_000, "text" => "Erste Stimme kehrt zurück" }
    ]

    words = [
      { "speaker_id" => "local_a", "start_ms" => 598_040, "end_ms" => 598_340, "text" => "zweite" },
      { "speaker_id" => "local_a", "start_ms" => 598_440, "end_ms" => 598_740, "text" => "Stimme" }
    ]

    assert_equal %w[speaker_2 speaker_1], @run.send(:stabilize_speakers, incoming, third, words).pluck("speaker_id")
  end

  test "assembly assigns overlap turns to exactly one chunk core" do
    first, second = prepare_chunks(duration_ms: 600_000)
    first.update!(status: "completed", output: { "turns" => [
      { "speaker_id" => "speaker_1", "start_ms" => 0, "end_ms" => 10_000, "text" => "Erster Teil" }
    ] })
    second.update!(status: "completed", output: { "turns" => [
      { "speaker_id" => "speaker_2", "start_ms" => 295_000, "end_ms" => 299_000, "text" => "Zweiter Teil" }
    ] })

    @run.send(:finalize_if_complete!)

    assert_equal [ "Erster Teil" ], @run.turns.pluck(:text)
  end

  test "assembly uses core-owned words so text and timestamps stay aligned across overlaps" do
    first, second = prepare_chunks(duration_ms: 600_000)
    first.update!(status: "completed", output: {
      "turns" => [ { "speaker_id" => "speaker_1", "start_ms" => 290_000, "end_ms" => 305_000,
        "text" => "Segment mit Überlappung" } ],
      "words" => [
        { "speaker_id" => "speaker_1", "start_ms" => 299_000, "end_ms" => 299_500, "text" => "Vorher" },
        { "speaker_id" => "speaker_1", "start_ms" => 301_000, "end_ms" => 301_500, "text" => "Doppelt" }
      ]
    })
    second.update!(status: "completed", output: {
      "turns" => [ { "speaker_id" => "speaker_1", "start_ms" => 295_000, "end_ms" => 310_000,
        "text" => "Anderes Segment mit Überlappung" } ],
      "words" => [
        { "speaker_id" => "speaker_1", "start_ms" => 299_020, "end_ms" => 299_520, "text" => "Vorher" },
        { "speaker_id" => "speaker_1", "start_ms" => 301_020, "end_ms" => 301_520, "text" => "Doppelt" },
        { "speaker_id" => "speaker_1", "start_ms" => 302_000, "end_ms" => 302_500, "text" => "danach." }
      ]
    })

    @run.send(:finalize_if_complete!)

    assert_equal [ "Vorher", "Doppelt danach." ], @run.turns.pluck(:text)
    assert_equal [ 299_000, 301_020 ], @run.turns.pluck(:start_ms)
  end

  test "assembly trims near-duplicate wording at a chunk boundary" do
    first, second = prepare_chunks(duration_ms: 600_000)
    first.update!(status: "completed", output: { "turns" => [
      { "speaker_id" => "speaker_1", "start_ms" => 280_000, "end_ms" => 299_000,
        "text" => "Macht es, weil ihr euch verbessern wollt und euch weiterentwickeln wollt. Das kann funktionieren, ich will ja nicht sagen, dass es nicht geht." }
    ] })
    second.update!(status: "completed", output: { "turns" => [
      { "speaker_id" => "speaker_1", "start_ms" => 295_000, "end_ms" => 325_000,
        "text" => "Euch verbessern wollt und euch weiterentwickeln wollt. Das kann funktionieren, ich will dir nicht sagen, dass es nichts bringt. Aber oft gibt es bessere Lösungen." }
    ] })

    @run.send(:finalize_if_complete!)

    assert_equal 2, @run.turns.count
    assert_equal "Aber oft gibt es bessere Lösungen.", @run.turns.second.text
  end

  test "approval is isolated from the current transcript and cannot approve incomplete work" do
    assert_raises(ActiveRecord::RecordInvalid) { @run.approve! }

    chunk = prepare_chunks(duration_ms: 1_000).first
    chunk.update!(status: "completed", output: { "turns" => [
      { "speaker_id" => "speaker_1", "start_ms" => 0, "end_ms" => 900, "text" => "Private pilot text" }
    ] })
    @run.send(:finalize_if_complete!)
    @run.approve!

    assert_equal "approved", @run.reload.review_status
    assert_equal "Pilot", @document.reload.title
  end

  test "publication requires reviewed speaker mappings and notifies transcript subscribers" do
    published_run = nil
    LongformTranscript.publication_callback = ->(run) { published_run = run }
    assert_raises(ActiveRecord::RecordInvalid) { @run.publish!("speaker_1" => "Host") }

    chunk = prepare_chunks(duration_ms: 1_000).first
    chunk.update!(status: "completed", output: { "turns" => [
      { "speaker_id" => "speaker_2", "start_ms" => 0, "end_ms" => 450, "text" => "Hallo" },
      { "speaker_id" => "speaker_1", "start_ms" => 450, "end_ms" => 900, "text" => "Antwort" }
    ] })
    @run.send(:finalize_if_complete!)

    assert_raises(ArgumentError) { @run.publish!("speaker_1" => "Host") }
    assert_raises(ArgumentError) { @run.publish!("speaker_1" => "Host", "speaker_2" => " ") }
    @run.speaker_mappings.create!(
      speaker_id: "speaker_1", display_name: "Previous review", reviewed_at: Time.current
    )
    @run.publish!("speaker_1" => "Host", "speaker_2" => "Guest")

    assert_equal "approved", @run.reload.review_status
    assert_equal @run, published_run
    assert_predicate @run, :published_at?
    assert_equal @run, @document.transcript_runs.published.sole
    assert_equal({ "speaker_1" => "Host", "speaker_2" => "Guest" },
      @run.speaker_mappings.pluck(:speaker_id, :display_name).to_h)
    assert_raises(ActiveRecord::StatementInvalid) { @run.update_column(:status, "failed") }
  ensure
    LongformTranscript.publication_callback = nil
  end

  test "a completed run never re-downloads or reprocesses audio" do
    chunk = prepare_chunks(duration_ms: 1_000).first
    chunk.update!(status: "completed", output: { "turns" => [
      { "speaker_id" => "speaker_1", "start_ms" => 0, "end_ms" => 900, "text" => "Done" }
    ] })
    @run.send(:finalize_if_complete!)
    @run.define_singleton_method(:ensure_audio!) { flunk("completed run must not touch audio") }

    assert_nil @run.process_next_chunk!
    assert_equal [ "Done" ], @run.turns.pluck(:text)
  end

  test "ffprobe and ffmpeg create a bounded local pilot clip" do
    FileUtils.mkdir_p(@run.audio_path.dirname)
    system("ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=1",
      "-ac", "1", "-ar", "16000", @run.audio_path.to_s, exception: true)
    duration = @run.send(:probe_duration_ms, @run.audio_path)
    @run.update!(source_audio_sha256: Digest::SHA256.file(@run.audio_path).hexdigest, audio_duration_ms: duration,
      status: "processing")
    chunk = @run.send(:prepare_chunks!, @run.source_audio_sha256, duration).then { @run.chunks.first }

    Dir.mktmpdir do |directory|
      clip = Pathname(directory).join("clip.mp3")
      @run.send(:create_clip!, chunk, clip)
      assert clip.file?
      assert_predicate clip.size, :positive?
    end
  end

  private

  def prepare_chunks(duration_ms:)
    @run.update!(source_audio_sha256: "b" * 64, audio_duration_ms: duration_ms, status: "processing")
    @run.send(:prepare_chunks!, @run.source_audio_sha256, duration_ms)
    @run.chunks.reload
  end
end
