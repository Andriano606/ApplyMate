# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Answer::ResolveConsent do
  let(:user) { build(:user) }

  def consent(user: self.user, **field)
    described_class.call(field: answer_field(semantic: 'consent_required', **field), user:)
  end

  it 'ticks a consent checkbox by policy (auto_consent defaults to true)' do
    expect(consent(kind: 'checkbox').model).to eq('value' => true, 'source' => 'policy', 'confidence' => 1.0)
  end

  it 'marks it policy_pending when the user opted out of automatic consent' do
    user.auto_consent = false

    expect(consent(kind: 'checkbox').model).to include('value' => true, 'source' => 'policy_pending')
  end

  it 'picks the affirmative option of a radio group by label' do
    options = [ { 'label' => 'I do not agree' }, { 'label' => 'I agree' } ]

    expect(consent(kind: 'radio_group', options:).model).to include('value' => 'I agree', 'source' => 'policy')
  end

  it 'picks the Ukrainian affirmative option of a select' do
    options = [ { 'label' => 'Ні' }, { 'label' => 'Так' } ]

    expect(consent(kind: 'select', options:).model).to include('value' => 'Так')
  end

  it 'answers a multiple choice with a list' do
    options = [ { 'label' => 'I acknowledge' }, { 'label' => 'Something else' } ]

    expect(consent(kind: 'checkbox_group', options:).model).to include('value' => [ 'I acknowledge' ])
  end

  it "affirms Ashby's GDPR checkbox group (the live Preply option is \"Acknowledge/Confirm\")" do
    options = [ { 'label' => 'Acknowledge/Confirm', 'value' => 'Acknowledge/Confirm' } ]

    expect(consent(kind: 'checkbox_group', options:).model).to include('value' => [ 'Acknowledge/Confirm' ], 'source' => 'policy')
  end

  it 'has no answer and the reason review without an affirmative option' do
    options = [ { 'label' => 'Maybe later' }, { 'label' => 'Never' } ]
    outcome = consent(kind: 'radio_group', options:)

    expect(outcome.model).to be_nil
    expect(outcome[:reason]).to eq(:review)
  end

  it 'has no answer and the reason review for a free-text consent' do
    outcome = consent(kind: 'text')

    expect(outcome.model).to be_nil
    expect(outcome[:reason]).to eq(:review)
  end
end
