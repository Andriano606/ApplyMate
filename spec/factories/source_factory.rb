# frozen_string_literal: true

FactoryBot.define do
  factory :source do
    name     { "Test Source" }
    base_url { "https://example.com" }
    client   { "ApplyMate::Client::Http" }

    after(:build) do |source|
      source.logo.attach(
        io:           Rails.root.join("spec/fixtures/files/photo.jpg").open,
        filename:     "logo.jpg",
        content_type: "image/jpeg"
      )
    end
  end
end
