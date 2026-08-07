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
  end
end
