# frozen_string_literal: true

# Seeds one review by another user (Feedback needs a unique author, which the
# generic table step cannot build).
Given('{string} has left a {int}\/10 feedback {string}') do |author, rating, text|
  create(:feedback, user: create(:user, name: author), rating:, body: text)
end
