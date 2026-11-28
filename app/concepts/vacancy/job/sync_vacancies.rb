# frozen_string_literal: true

require 'async'

class Vacancy::Job::SyncVacancies < ApplicationJob
  queue_as :default

  # The in-memory proxy pool owns the per-run use limit (ProxyPool::MAX_USES requests per
  # proxy per site, ProxyPool::USE_INTERVAL seconds apart), and each run has its own ProxyMate
  # sessions — so only one sync may run at a time: a second run would get the same proxies in
  # its own sessions and use them on top of the first run's limit.
  # Solid Queue's default concurrency window is 3 minutes; a full sync runs for hours.
  # Without an explicit duration the semaphore expires mid-run and a second trigger
  # (manual, retry, another worker) starts a parallel pool handing out the same IPs —
  # the use counts live in RAM and cannot see the other run.
  limits_concurrency to: 1, key: 'vacancy_sync_vacancies', duration: 12.hours

  def perform
    Vacancy::Operation::SyncVacancies.call
  end
end
