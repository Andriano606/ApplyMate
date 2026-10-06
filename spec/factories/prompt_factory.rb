# frozen_string_literal: true

FactoryBot.define do
  factory :prompt do
    user
    name        { 'Fill form prompt' }
    prompt_type { :fill_form }
    content do
      <<~CONTENT
        Custom template.
        PLACEHOLDER_VACANCY_CONTEXT
        PLACEHOLDER_USER_EXPERIENCE
        PLACEHOLDER_FORM_FIELDS
      CONTENT
    end

    trait :generate_cv do
      name        { 'Generate CV prompt' }
      prompt_type { :generate_cv }
      content do
        <<~CONTENT
          Custom template.
          PLACEHOLDER_USER_PROFILE
          PLACEHOLDER_VACANCY_TITLE
          PLACEHOLDER_VACANCY_DESCRIPTION
        CONTENT
      end
    end
  end
end
