# frozen_string_literal: true

class UserProfile::Job::ExtractFacts < ApplicationJob
  queue_as :apply

  # One AI call per profile; the key prefix follows UserProfile's own id space.
  limits_concurrency to: 1, key: ->(user_profile_id) { "user_profile_facts:#{user_profile_id}" }, duration: 10.minutes

  # Transient AI failures (an empty or malformed reply, a timeout, a network error, GeminiScraping's local Chrome slot
  # staying taken) get a few spaced retries; after that the job ends and Stage::AnswerFields extracts the facts inline
  # at the profile's next apply.
  retry_on ApplyMate::Ai::Client::Base::EmptyResponse, ApplyMate::Ai::ResponseSchema::Json::InvalidResponse,
           ApplyMate::Ai::Client::GeminiScraping::ResponseTimeoutError, ApplyMate::Client::LocalChrome::Busy,
           ApplyMate::Ai::Client::Base::Unavailable, Faraday::Error,
           attempts: 3, wait: :polynomially_longer

  def perform(user_profile_id)
    UserProfile::Operation::ExtractFacts.call(user_profile: UserProfile.find(user_profile_id))
  end
end
