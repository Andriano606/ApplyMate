# frozen_string_literal: true

FactoryBot.define do
  factory :feedback do
    association :user
    rating { 8 }
    sequence(:body) { |n| "Useful vacancy bank, review ##{n}" }
    posted_via { 'web' }
  end
end
