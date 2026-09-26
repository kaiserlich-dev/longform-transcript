module LongformTranscript
  class TranscriptSchema < Schematist::Schema
    array :turns do
      object do
        string :speaker_id
        integer :start_ms, minimum: 0
        integer :end_ms, minimum: 1
        string :text
      end
    end
  end
end
