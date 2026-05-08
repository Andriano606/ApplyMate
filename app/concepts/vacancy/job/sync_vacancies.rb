# frozen_string_literal: true

require 'async'

class Vacancy::Job::SyncVacancies < ApplicationJob
  queue_as :default

  def perform
    Vacancy::Operation::SyncVacancies.call
  end
end
