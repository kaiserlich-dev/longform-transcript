require "test_helper"

class LongformTranscriptRunConcurrencyTest < ActiveSupport::TestCase
  test "concurrent starts resolve to one versioned run" do
    document = Document.create!(title: "Concurrent")
    gate = Queue.new
    threads = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          gate.pop
          begin
            LongformTranscript.prepare_for!(Document.find(document.id),
              source_audio_url: "https://audio.example/concurrent.mp3",
              model: "openai/test-transcribe", profile: profile).id
          rescue ActiveRecord::StatementTimeout
            retry
          end
        end
      end
    end
    2.times { gate << true }

    assert_equal 1, threads.map(&:value).uniq.size
    assert_equal 1, document.transcript_runs.count
  ensure
    LongformTranscript::Run.where(transcribable: document).delete_all if document
    document&.destroy!
  end
end
