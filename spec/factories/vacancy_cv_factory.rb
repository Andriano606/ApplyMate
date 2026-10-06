# frozen_string_literal: true

FactoryBot.define do
  factory :vacancy_cv do
    vacancy            { association :vacancy, source: association(:source) }
    user_profile
    ai_integration     { association :ai_integration, user: user_profile.user }
    generate_cv_prompt { association :prompt, :generate_cv, user: user_profile.user }
  end
end
