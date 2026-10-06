# frozen_string_literal: true

FactoryBot.define do
  factory :apply do
    user
    vacancy        { association :vacancy, source: association(:source) }
    user_profile   { association :user_profile, user: }
    ai_integration { association :ai_integration, user: }
    source_profile { association :source_profile, user:, source: vacancy.source }
  end
end
