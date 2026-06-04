# frozen_string_literal: true

FactoryBot.define do
  factory :user do
    sequence(:email) { |n| "user#{n}@example.com" }
    name             { "Test User" }
    provider         { "google_oauth2" }
    sequence(:uid)   { |n| "uid-#{n}" }

    trait :admin do
      admin { true }
    end
  end
end
