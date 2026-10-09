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
  create_my_apply(status, filled_inputs: table.hashes.map { |row| row.transform_values { |v| expand_unique(v) } })
end

Given('I have a {string} apply with a CV for the last Vacancy') do |state|
  create_my_apply(state).cv.attach(io: StringIO.new('%PDF-1.4 fake'), filename: 'cv.pdf', content_type: 'application/pdf')
end

# Fields + answers for the review form; the table columns are id, kind, label, value and answer source.
Given('I have a {string} apply for the last Vacancy waiting for review with the answers:') do |state, table|
  fields = table.hashes.map do |row|
    Apply::Field.new(**Apply::Field.members.index_with { nil }.merge(
      id: row['id'], kind: row['kind'], label: row['label'], required: false, widget: 'text', ordinal: 0,
      source: 'snapshot', semantic: 'other'
    )).to_h
  end
  answers = table.hashes.to_h do |row|
    [ row['id'], { 'value' => row['value'], 'source' => row['source'], 'confidence' => 0.8 } ]
  end
  apply = create_my_apply(state)
  apply.update!(fields:, answers:, form_url: 'https://jobs.ashbyhq.com/acme/1/application',
                failure: { code: 'review', kind: 'human', detail: 'low_confidence' })
end

# Approving queues the engine job; Cucumber runs jobs inline, so stub the enqueue to keep the real engine out.
Given('the apply engine job is not run') do
  allow(Apply::Job::Apply).to receive(:perform_later).and_return(instance_double(Apply::Job::Apply, job_id: 'job-1'))
end
