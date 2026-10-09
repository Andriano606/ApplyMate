# frozen_string_literal: true

FactoryBot.define do
  factory :apply do
    user
    vacancy        { association :vacancy, source: association(:source) }
    user_profile   { association :user_profile, user: }
    ai_integration { association :ai_integration, user: }
    source_profile { association :source_profile, user:, source: vacancy.source }

    trait :running do
      state       { :running }
      stage       { 'generate_cv' }
      run_token   { SecureRandom.uuid }
      attempt     { 1 }
      heartbeat_at { Time.current }
      deadline_at { 30.minutes.from_now }
    end

    trait :completed do
      state         { :completed }
      submitted_at  { Time.current }
      submitted_via { 'engine' }
    end

    trait :failed do
      state   { :failed }
      failure { { code: 'unexpected_error', kind: 'permanent' } }
    end

    trait :claimed do
      state             { :submit_unverified }
      submit_claimed_at { Time.current }
      failure           { { code: 'outcome_unknown', kind: 'permanent' } }
    end

    trait :needs_human do
      state   { :needs_human }
      failure { { code: 'manual_apply_required', kind: 'human' } }
    end
  end
end
