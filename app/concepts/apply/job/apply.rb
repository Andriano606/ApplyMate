# frozen_string_literal: true

class Apply::Job::Apply < ApplicationJob
  queue_as :default

  def perform(apply_id)
    apply = Apply.find(apply_id)
    Apply::Handler::Base.for(apply).call
  end
end
