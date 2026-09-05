# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Ai::Prompt::FillForm do
  include_context 'honeytech dou'

  subject(:prompt) { described_class.call(apply, fields) }

  let(:fields) do
    [ { 'fingerprint' => 'fp-salary', 'accessible_name' => 'Desired base compensation',
        'name' => 'salary', 'tag' => 'input', 'type' => 'text', 'role' => 'salary_expectation' },
      { 'fingerprint' => 'fp-cover', 'accessible_name' => 'Cover letter',
        'name' => 'message', 'tag' => 'textarea', 'type' => 'textarea', 'role' => 'cover_letter' } ]
  end

  it 'asks for the fields by fingerprint, which is what the schema keys on' do
    expect(prompt).to include('fp-salary', 'fp-cover')
  end

  # Forms validate compensation as a number and reject "3000$ (gross)". The
  # value is normalised afterwards regardless, but asking correctly costs
  # nothing and keeps the stored answer usable.
  it 'demands a bare number for salary' do
    expect(prompt).to match(/ЛИШЕ число/)
  end

  it 'gives the cover letter its own instruction' do
    expect(prompt).to include('Мотиваційний лист')
  end

  it 'carries the user experience the answers are drawn from' do
    expect(prompt).to include(apply.user_profile.cv)
  end

  it 'is nil when there is nothing to generate' do
    expect(described_class.call(apply, [])).to be_nil
  end
end
