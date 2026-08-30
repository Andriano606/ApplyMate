# frozen_string_literal: true

require 'async'

class Vacancy::Job::SyncVacancies < ApplicationJob
  queue_as :default

  # The in-memory proxy pool owns the "one proxy at most once per 5s" rule, so
  # only one sync may run at a time — two concurrent runs would share proxies
  # faster than the cooldown allows.
  # Solid Queue's default concurrency window is 3 minutes; a full sync runs for hours.
  # Without an explicit duration the semaphore expires mid-run and a second trigger
  # (manual, retry, another worker) starts a parallel pool handing out the same IPs —
  # the burst/cooldown bookkeeping lives in RAM and cannot see the other run.
  limits_concurrency to: 1, key: 'vacancy_sync_vacancies', duration: 12.hours

  def perform
    Vacancy::Operation::SyncVacancies.call
  end
end
