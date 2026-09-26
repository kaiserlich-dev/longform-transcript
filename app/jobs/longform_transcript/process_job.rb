module LongformTranscript
  class ProcessJob < ActiveJob::Base
    queue_as { LongformTranscript.queue_name }
    retry_on Run::ExternalFailure, wait: :polynomially_longer, attempts: 3

    def perform(run_id)
      run = Run.find(run_id)
      run.process_next_batch!
      self.class.perform_later(run.id) if run.work_remaining?
    rescue Run::ExternalFailure => error
      run&.record_source_failure!(error)
      raise if error.retryable?
    end
  end
end
