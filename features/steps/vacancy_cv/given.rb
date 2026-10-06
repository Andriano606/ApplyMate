Given('I have a generated CV for the last Vacancy') do
  user = User.find_by!(email: OmniAuth.config.mock_auth[:google_oauth2].info.email)
  vacancy_cv = create(:vacancy_cv, vacancy: Vacancy.last, user_profile: create(:user_profile, user:), created_at: 1.day.ago)
  vacancy_cv.cv.attach(io: StringIO.new('%PDF-1.4 fake'), filename: 'cv.pdf', content_type: 'application/pdf')
end
