# frozen_string_literal: true

class Apply::Job::Apply < ApplicationJob
  queue_as :apply

  # A DOU external apply makes up to 5 AI calls (GeminiScraping ~4 min each) plus two
  # Chrome sessions and Grover, so the duration is sized to that runtime (Solid Queue's
  # default window is 3 minutes). The key blocks a duplicate run of the same Apply; the
  # apply worker's threads (APPLY_SLOTS) cap the number of concurrent browsers. The run's
  # own ownership for its full length is enforced by applies.run_token + heartbeat
  # (Apply::Operation::Engine::StartContext / FencedUpdate), not by this window.
  # `apply:<id>` is reserved for Apply ids (VacancyCv/VacancyQuestion use their own prefixes).
  limits_concurrency to: 1, key: ->(apply_id) { "apply:#{apply_id}" }, duration: 45.minutes

  # No free browser slot (PoolBusy): the Runner parks the row in waiting_capacity and re-raises. Eight attempts of
  # polynomially_longer waits (7 retries, executions**4 + 2 s each: 4 690 s ≈ 78 min, up to ≈ 90 min with the 15%
  # retry jitter) is the termination path; after that HaltUnowned writes failed(:capacity) and the user Resumes.
  # The block runs instead of re-raising, so the job ends cleanly. ReapStale judges the newest solid_queue_jobs row
  # of the active_job_id (each retry adds one), so the scheduled retry counts as alive for the whole wait.
  MAX_CAPACITY_RETRIES = 8
  retry_on ApplyMate::Client::Browser::PoolBusy, attempts: MAX_CAPACITY_RETRIES, wait: :polynomially_longer do |job, error|
    Apply::Operation::Engine::Lifecycle::HaltUnowned.call(apply_id: job.arguments.first, code: :capacity,
                                                          detail: error.message)
  end

  # The Runner records every outcome of a started run itself (and swallows NotStartable/Fenced).
  # What reaches the rescue failed before a run owned the row (handler resolution) or while
  # recording; HaltUnowned writes only queued/waiting_capacity rows, so a live run is untouched.
  def perform(apply_id)
    apply = Apply.find(apply_id)
    Apply::Handler::Base.for(apply).call
  rescue ActiveRecord::RecordNotFound
    nil
  rescue ApplyMate::Client::Browser::PoolBusy
    raise # the Runner already recorded waiting_capacity; retry_on decides the rest, never unexpected_error
  rescue StandardError => e
    Apply::Operation::Engine::Lifecycle::HaltUnowned.call(apply_id:, code: :unexpected_error, detail: e.class.name)
    raise
  end
end
