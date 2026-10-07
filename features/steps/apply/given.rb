# States with a factory trait get their invariants (failure hash, submitted_at, ...) from it.
APPLY_STATE_TRAITS = %w[running completed failed claimed needs_human].freeze

def create_my_apply(state, filled_inputs: nil)
  user = User.find_by!(email: OmniAuth.config.mock_auth[:google_oauth2].info.email)
  attrs = { user:, vacancy: Vacancy.last, filled_inputs: }
  return create(:apply, state.to_sym, **attrs) if APPLY_STATE_TRAITS.include?(state)

  create(:apply, state:, **attrs)
end

Given('I have a {string} apply for the last Vacancy') do |state|
  create_my_apply(state)
end

Given('I have a {string} apply for the last Vacancy with the filled form:') do |status, table|
  create_my_apply(status, filled_inputs: table.hashes)
end

Given('I have a {string} apply with a CV for the last Vacancy') do |state|
  create_my_apply(state).cv.attach(io: StringIO.new('%PDF-1.4 fake'), filename: 'cv.pdf', content_type: 'application/pdf')
end
