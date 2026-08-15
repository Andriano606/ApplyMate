# frozen_string_literal: true

FactoryBot.define do
  factory :answer_bank do
    user_profile
    role   { 'email' }
    answer { 'dev@example.com' }
    source { :manual }

    trait :custom do
      role     { 'custom_question' }
      question { 'how many years of experience with react?' }
      answer   { '5 years' }
    end
  end
end
