require "tmpdir"

ENV["RAILS_ENV"] = "test"
ENV["DATABASE_URL"] = "sqlite3:#{File.join(Dir.tmpdir, "longform-transcript-test.sqlite3")}"
require "bundler/setup"
require "rails"
require "active_record/railtie"
require "active_job/railtie"
require "minitest/autorun"
require "active_job/test_helper"
require "webmock/minitest"
require "longform_transcript"

class TestApplication < Rails::Application
  config.eager_load = false
  config.logger = Logger.new(nil)
  config.active_job.queue_adapter = :test
  config.root = Pathname(__dir__).join("dummy")
  config.secret_key_base = "test"
end

TestApplication.initialize!
ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: File.join(Dir.tmpdir, "longform-transcript-test.sqlite3"))
ActiveRecord::Migration.verbose = false
load File.expand_path("../db/migrate/20260926000000_create_longform_transcript_tables.rb", __dir__)
CreateLongformTranscriptTables.migrate(:down) if ActiveRecord::Base.connection.table_exists?(:longform_transcript_runs)
CreateLongformTranscriptTables.migrate(:up)
ActiveRecord::Schema.define do
  create_table :documents, force: true do |t|
    t.string :title
  end
end

class Document < ActiveRecord::Base
end

LongformTranscript.storage_root = Pathname(Dir.tmpdir).join("longform-transcript-tests")

class ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    LongformTranscript::SpeakerMapping.delete_all
    LongformTranscript::Turn.delete_all
    LongformTranscript::Chunk.delete_all
    LongformTranscript::Run.delete_all
    Document.delete_all
    clear_enqueued_jobs
  end

  def profile
    { version: "test-v1", interface: :transcription, provider: :openrouter,
      provider_options: { "sort" => "latency" } }
  end

  def prepared_run(url: "https://audio.example/show.mp3?token=one")
    LongformTranscript.prepare_for!(Document.create!(title: "Show"), source_audio_url: url,
      model: "openai/test-transcribe", profile: profile)
  end

  def prepare_chunks(run, duration: 600_000)
    run.update!(source_audio_sha256: "a" * 64, audio_duration_ms: duration, status: "processing")
    run.send(:prepare_chunks!, run.source_audio_sha256, duration)
    run.chunks.reload
  end
end
