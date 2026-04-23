# frozen_string_literal: true

FactoryBot.define do
  factory :vacancy do
    sequence(:external_id) { |n| "ext-#{n}" }
    title           { "Ruby Developer" }
    company_name    { "Acme Corp" }
    description     { "We are looking for a Ruby developer." }
    url             { "https://example.com/jobs/1" }
    company_icon_url { nil }
  end
end
