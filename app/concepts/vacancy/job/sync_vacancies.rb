# frozen_string_literal: true

require 'async'

class Vacancy::Job::SyncVacancies < ApplicationJob
  queue_as :default

  # The in-memory proxy pool owns the "one proxy at most once per 5s" rule, so
  # only one sync may run at a time — two concurrent runs would share proxies
  # faster than the cooldown allows.
  limits_concurrency to: 1, key: 'vacancy_sync_vacancies'

  def perform
    Vacancy::Operation::SyncVacancies.call
  end
end
