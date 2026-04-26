# frozen_string_literal: true

class Apply::Job::GenerateCv < ApplicationJob
  queue_as :default

  def perform(apply_id)
    Apply::Operation::GeneratePdfCv.call(apply_id:)
  end
end
