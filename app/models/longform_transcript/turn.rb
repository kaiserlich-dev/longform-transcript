module LongformTranscript
  class Turn < ApplicationRecord
    belongs_to :run
    belongs_to :chunk
    validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, uniqueness: { scope: :run_id }
    validates :start_ms, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :end_ms, numericality: { only_integer: true, greater_than: :start_ms }
    validates :speaker_id, format: { with: /\Aspeaker_[1-9]\d*\z/ }
    validates :text, presence: true
  end
end
