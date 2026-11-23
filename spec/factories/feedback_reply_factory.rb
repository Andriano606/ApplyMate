# frozen_string_literal: true

FactoryBot.define do
  factory :feedback_reply do
    feedback
    association :user, :admin
    sequence(:body) { |n| "Thanks for the feedback, reply ##{n}" }
  end
end
