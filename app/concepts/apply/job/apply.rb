# frozen_string_literal: true

class Apply::Job::Apply < ApplicationJob
  queue_as :apply

  # A DOU external apply makes up to 5 AI calls (GeminiScraping ~4 min each) plus two
  # Chrome sessions and Grover, so the duration is sized to that runtime (Solid Queue's
  # default window is 3 minutes). The key blocks a duplicate run of the same Apply; the
  # apply worker's threads (APPLY_SLOTS) cap the number of concurrent browsers.
  # `apply:<id>` is reserved for Apply ids (VacancyCv/VacancyQuestion use their own prefixes).
  limits_concurrency to: 1, key: ->(apply_id) { "apply:#{apply_id}" }, duration: 45.minutes

  def perform(apply_id)
    apply = Apply.find(apply_id)
    Apply::Handler::Base.for(apply).call
  end
end
