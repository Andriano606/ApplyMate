def create_my_apply(status, filled_inputs: nil)
  user = User.find_by!(email: OmniAuth.config.mock_auth[:google_oauth2].info.email)
  create(:apply, user:, vacancy: Vacancy.last, status:, filled_inputs:)
end

Given('I have a {string} apply for the last Vacancy') do |status|
  create_my_apply(status)
end

Given('I have a {string} apply for the last Vacancy with the filled form:') do |status, table|
  create_my_apply(status, filled_inputs: table.hashes)
end

Given('I have a {string} apply with a CV for the last Vacancy') do |status|
  create_my_apply(status).cv.attach(io: StringIO.new('%PDF-1.4 fake'), filename: 'cv.pdf', content_type: 'application/pdf')
end
