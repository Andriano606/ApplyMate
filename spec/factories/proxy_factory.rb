# frozen_string_literal: true

FactoryBot.define do
  factory :proxy do
    sequence(:host) { |n| "proxy#{n}.example.com" }
    port            { 8080 }
    protocol        { "http" }
  end
end
