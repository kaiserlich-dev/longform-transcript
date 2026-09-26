module LongformTranscript
  class Chunk < ApplicationRecord
    MAX_RETRIES = 3
    STATUSES = %w[pending processing completed failed].freeze

    belongs_to :run
    has_many :turns, dependent: :restrict_with_exception
    validates :number, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, uniqueness: { scope: :run_id }
    validates :start_ms, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :end_ms, numericality: { only_integer: true, greater_than: :start_ms }
    validates :retry_count, inclusion: { in: 0..MAX_RETRIES }
    validates :source_digest, :status, presence: true
    validates :status, inclusion: { in: STATUSES }
    scope :ordered, -> { order(:number) }

    def retry_available? = retryable? && retry_count < MAX_RETRIES
    def core_start_ms = number * LongformTranscript.chunk_duration.in_milliseconds
    def core_end_ms = [ (number + 1) * LongformTranscript.chunk_duration.in_milliseconds, run.audio_duration_ms ].min
  end
end
