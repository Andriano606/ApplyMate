# frozen_string_literal: true

FactoryBot.define do
  factory :api_token do
    association :user
    name { "Test token" }
  end
end
