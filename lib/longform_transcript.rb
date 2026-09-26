require "rails"
require "active_record"
require "active_job"
require "active_support/core_ext/numeric/time"
require "ruby_llm"
require "longform_transcript/version"
require "longform_transcript/engine"

module LongformTranscript
  class << self
    attr_accessor :storage_root, :queue_name, :chunk_duration, :chunk_overlap, :download_limit,
      :stale_after, :publication_callback

    def configure
      yield self
    end

    def prepare_for!(transcribable, source_audio_url:, model:, profile:)
      Run.prepare_for!(transcribable, source_audio_url: source_audio_url, model: model, profile: profile)
    end
  end

  self.storage_root = -> { Rails.root.join(Rails.env.production? ? "data/longform_transcripts" : "tmp/longform_transcripts") }
  self.queue_name = :transcripts
  self.chunk_duration = 5.minutes
  self.chunk_overlap = 5.seconds
  self.download_limit = 1024**3
  self.stale_after = 30.minutes
end
