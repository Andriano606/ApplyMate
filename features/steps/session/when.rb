# frozen_string_literal: true

# Switches between several users inside one scenario. The generic OAuth mock uses
# one fixed uid, so every user here gets a uid derived from the email.
When('I sign in as {string} with email {string}') do |name, email|
  OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
    provider: 'google_oauth2', uid: "uid-#{email}", info: { email:, name: }
  )
  visit '/auth/google_oauth2'
  expect(page).to have_no_link(I18n.t('navbar.sign_in'))
  wait_for { User.find_by(email:) }.to be_present
end

When('I sign out') do
  find(:link_or_button, I18n.t('navbar.sign_out'), visible: :all, match: :first).execute_script('this.click()')
  expect(page).to have_link(I18n.t('navbar.sign_in'))
end
