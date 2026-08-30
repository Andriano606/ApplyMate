# frozen_string_literal: true

FactoryBot.define do
  factory :proxy_source_stat do
    proxy
    source
    success_count { 1 }
    fail_count    { 0 }
    reliability   { 1.0 }
  end
end
