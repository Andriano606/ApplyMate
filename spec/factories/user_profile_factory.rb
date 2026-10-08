# frozen_string_literal: true

FactoryBot.define do
  factory :user_profile do
    user
    name { 'Main Profile' }
    cv   { 'Senior Ruby developer with 8 years of experience.' }
    # Facts already extracted for this CV (Stage::AnswerFields makes no extraction call); pass nil for a profile
    # whose facts were never extracted.
    facts_cv_digest { Digest::SHA256.hexdigest(cv.to_s) }
  end
end
