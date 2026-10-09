# frozen_string_literal: true

FactoryBot.define do
  factory :apply_step do
    apply
    attempt    { 1 }
    sequence(:key) { |n| "step_#{n}" }
    stage      { 'fetch_details' }
    sequence(:position)
    state      { :running }
    started_at { Time.current }
  end
end
