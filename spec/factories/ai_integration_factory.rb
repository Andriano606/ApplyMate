# frozen_string_literal: true

FactoryBot.define do
  factory :ai_integration do
    user
    provider { 'gemini' }
    api_key  { 'test-api-key' }
    model    { 'gemini-2.5-flash' }
  end
end
