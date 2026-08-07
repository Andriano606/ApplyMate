# frozen_string_literal: true

FactoryBot.define do
  factory :user_profile do
    user
    name { 'Main Profile' }
    cv   { 'Senior Ruby developer with 8 years of experience.' }
  end
end
