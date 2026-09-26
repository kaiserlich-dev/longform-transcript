module LongformTranscript
  class SpeakerMapping < ApplicationRecord
    belongs_to :run
    validates :speaker_id, format: { with: /\Aspeaker_[1-9]\d*\z/ }, uniqueness: { scope: :run_id }
    validates :display_name, :reviewed_at, presence: true
  end
end
