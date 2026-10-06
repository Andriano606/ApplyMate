# frozen_string_literal: true

FactoryBot.define do
  factory :source_profile do
    user
    source
    name        { 'My Source Profile' }
    auth_method { :session_id }
    session_id  { 'test-session-id' }
  end
end
