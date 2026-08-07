# frozen_string_literal: true

FactoryBot.define do
  factory :vacancy_question do
    vacancy
    user_profile
    ai_integration   { association :ai_integration, user: user_profile.user }
    fill_form_prompt { association :prompt, user: user_profile.user }
    question         { 'Чому ви хочете працювати саме у нашій компанії?' }
  end
end
