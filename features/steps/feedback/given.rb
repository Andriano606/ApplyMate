# frozen_string_literal: true

# Seeds one review by another user (Feedback needs a unique author, which the
# generic table step cannot build).
Given('{string} has left a {int}\/10 feedback {string}') do |author, rating, text|
  create(:feedback, user: create(:user, name: author), rating:, body: text)
end

Given('an admin {string} has replied {string} under the review by {string}') do |admin_name, text, author|
  feedback = Feedback.joins(:user).find_by!(users: { name: author })
  admin = User.find_by(name: admin_name, admin: true) || create(:user, :admin, name: admin_name)
  create(:feedback_reply, feedback:, user: admin, body: text)
end
