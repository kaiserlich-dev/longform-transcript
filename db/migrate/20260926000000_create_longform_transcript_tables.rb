class CreateLongformTranscriptTables < ActiveRecord::Migration[7.1]
  def change
    create_table :longform_transcript_runs do |t|
      t.references :transcribable, polymorphic: true, null: false, index: false
      t.text :source_audio_url, null: false
      t.string :source_audio_identity, null: false
      t.string :source_audio_sha256
      t.integer :audio_duration_ms
      t.string :model, null: false
      t.json :profile, null: false, default: {}
      t.string :prompt_version, null: false
      t.string :schema_version, null: false
      t.string :status, null: false, default: "prepared"
      t.string :review_status, null: false, default: "pending_review"
      t.datetime :audio_claimed_at
      t.datetime :started_at
      t.datetime :completed_at
      t.datetime :failed_at
      t.datetime :reviewed_at
      t.datetime :published_at
      t.integer :input_tokens, null: false, default: 0
      t.integer :output_tokens, null: false, default: 0
      t.decimal :reported_cost_usd, precision: 12, scale: 6, null: false, default: 0
      t.integer :total_latency_ms, null: false, default: 0
      t.string :failure_code
      t.timestamps
    end
    add_index :longform_transcript_runs,
      %i[transcribable_type transcribable_id source_audio_identity model prompt_version schema_version],
      unique: true, name: "idx_longform_runs_versioned_identity"
    add_index :longform_transcript_runs, %i[transcribable_type transcribable_id], unique: true,
      where: "published_at IS NOT NULL", name: "idx_longform_runs_one_published"
    add_check_constraint :longform_transcript_runs,
      "status IN ('prepared', 'processing', 'completed', 'failed')", name: "longform_runs_known_status"
    add_check_constraint :longform_transcript_runs,
      "review_status IN ('pending_review', 'approved', 'rejected')", name: "longform_runs_known_review_status"
    add_check_constraint :longform_transcript_runs,
      "published_at IS NULL OR (status = 'completed' AND review_status = 'approved')",
      name: "longform_runs_valid_publication"

    create_table :longform_transcript_chunks do |t|
      t.references :run, null: false, foreign_key: { to_table: :longform_transcript_runs }, index: false
      t.integer :number, null: false
      t.integer :start_ms, null: false
      t.integer :end_ms, null: false
      t.string :source_digest, null: false
      t.string :status, null: false, default: "pending"
      t.integer :retry_count, null: false, default: 0
      t.boolean :retryable, null: false, default: true
      t.string :failure_code
      t.string :model
      t.integer :input_tokens, null: false, default: 0
      t.integer :output_tokens, null: false, default: 0
      t.decimal :reported_cost_usd, precision: 12, scale: 6, null: false, default: 0
      t.integer :latency_ms, null: false, default: 0
      t.json :output, null: false, default: {}
      t.datetime :claimed_at
      t.datetime :started_at
      t.datetime :completed_at
      t.datetime :failed_at
      t.timestamps
    end
    add_index :longform_transcript_chunks, %i[run_id number], unique: true
    add_index :longform_transcript_chunks, %i[run_id status number]
    add_check_constraint :longform_transcript_chunks,
      "status IN ('pending', 'processing', 'completed', 'failed')", name: "longform_chunks_known_status"
    add_check_constraint :longform_transcript_chunks, "number >= 0 AND start_ms >= 0 AND end_ms > start_ms AND retry_count BETWEEN 0 AND 3",
      name: "longform_chunks_valid_bounds"

    create_table :longform_transcript_turns do |t|
      t.references :run, null: false, foreign_key: { to_table: :longform_transcript_runs }, index: false
      t.references :chunk, null: false, foreign_key: { to_table: :longform_transcript_chunks }, index: false
      t.integer :position, null: false
      t.integer :start_ms, null: false
      t.integer :end_ms, null: false
      t.string :speaker_id, null: false
      t.text :text, null: false
      t.timestamps
    end
    add_index :longform_transcript_turns, %i[run_id position], unique: true
    add_index :longform_transcript_turns, %i[run_id start_ms]
    add_check_constraint :longform_transcript_turns, "position >= 0 AND start_ms >= 0 AND end_ms > start_ms",
      name: "longform_turns_valid_bounds"

    create_table :longform_transcript_speaker_mappings do |t|
      t.references :run, null: false, foreign_key: { to_table: :longform_transcript_runs }, index: false
      t.string :speaker_id, null: false
      t.string :display_name, null: false
      t.datetime :reviewed_at, null: false
      t.timestamps
    end
    add_index :longform_transcript_speaker_mappings, %i[run_id speaker_id], unique: true,
      name: "idx_longform_mappings_run_speaker"
  end
end
