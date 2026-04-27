# frozen_string_literal: true

class Apply::Job::Apply < ApplicationJob
  queue_as :default

  def perform(apply_id)
    apply = Apply.find(apply_id)
    Apply::Operation::FetchDetails.call(apply:)
    Apply::Operation::GeneratePdfCv.call(apply_id:)
  end
end
