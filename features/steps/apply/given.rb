# frozen_string_literal: true

# An apply of the signed-in user (the OmniAuth mock in features/support/omniauth.rb) for the last Vacancy.
# Apply needs a profile, an AI integration and a source profile, so it is built with FactoryBot.
def create_my_apply(status, filled_inputs: nil)
  user = User.find_by!(email: OmniAuth.config.mock_auth[:google_oauth2].info.email)
  create(:apply, user:, vacancy: Vacancy.last, status:, filled_inputs:)
end

Given('I have a {string} apply for the last Vacancy') do |status|
  create_my_apply(status)
end

# Examples:
#   Given I have a "completed" apply for the last Vacancy with the filled form:
#     | tag      | type     | label   | value        |
#     | textarea | textarea | Why us? | I love Ruby  |
Given('I have a {string} apply for the last Vacancy with the filled form:') do |status, table|
  create_my_apply(status, filled_inputs: table.hashes)
end
