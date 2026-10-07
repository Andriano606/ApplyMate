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

  # The Runner records every outcome of a started run itself (and swallows NotStartable/Fenced).
  # What reaches the rescue failed before a run owned the row (handler resolution) or while
  # recording; HaltUnowned writes only queued/waiting_capacity rows, so a live run is untouched.
  def perform(apply_id)
    apply = Apply.find(apply_id)
    Apply::Handler::Base.for(apply).call
  rescue ActiveRecord::RecordNotFound
    nil
  rescue StandardError => e
    Apply::Operation::Engine::Lifecycle::HaltUnowned.call(apply_id:, code: :unexpected_error, detail: e.class.name)
    raise
  end
end
