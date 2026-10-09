# frozen_string_literal: true

require 'rails_helper'

RSpec.describe UserProfile::Operation::ExtractFacts, type: :operation do
  let(:user)          { create(:user) }
  let(:cv_email)      { unique_email('jane') }
  let(:user_edited_email) { unique_email('mine') }
  let(:user_profile)  { create(:user_profile, user:, cv: "Jane Doe, #{cv_email}, 8y Ruby", facts_cv_digest: nil) }
  let(:current_user)  { user }
  let(:params)        { { user_profile: } }
  let(:gemini_url)    { /generativelanguage\.googleapis\.com.*generateContent/ }
  let(:ai_json) do
    %({"full_name":"Jane Doe","email":"#{cv_email}","phone":null,"years_experience":"8","languages":["English"]})
  end

  def perform
    described_class.call(user_profile:)
  end

  before do
    ai = create(:ai_integration, user:)
    user.update!(default_ai_integration: ai)
    stub_request(:post, gemini_url).to_return(gemini_json_response(ai_json))
  end

  it 'stores AI facts without nulls and the CV digest' do
    perform
    user_profile.reload

    expect(user_profile.facts['ai']).to eq(
      'full_name' => 'Jane Doe', 'email' => cv_email, 'years_experience' => '8', 'languages' => [ 'English' ]
    )
    expect(user_profile.facts['user']).to eq({})
    expect(user_profile.facts_cv_digest).to eq(Digest::SHA256.hexdigest(user_profile.cv))
  end

  it 'is skipped while the CV digest is unchanged' do
    perform
    perform

    expect(a_request(:post, gemini_url)).to have_been_made.once
  end

  it 'extracts again after the CV changes' do
    perform
    user_profile.update!(cv: 'New CV text')
    perform

    expect(a_request(:post, gemini_url)).to have_been_made.twice
  end

  it 'keeps user-edited facts and lets them win over AI facts' do
    user_profile.update!(facts: { 'user' => { 'email' => user_edited_email } })

    perform
    user_profile.reload

    expect(user_profile.facts['user']).to eq('email' => user_edited_email)
    expect(user_profile.facts['ai']['email']).to eq(cv_email)
    expect(user_profile.fact(:email)).to eq(user_edited_email)
    expect(user_profile.fact(:full_name)).to eq('Jane Doe')
    expect(user_profile.fact(:phone)).to be_nil
  end

  it 'uses an explicitly given integration over the missing default (the inline call from Stage::AnswerFields)' do
    integration = create(:ai_integration, user:)
    user.update!(default_ai_integration: nil)

    described_class.call(user_profile:, ai_integration: integration)

    expect(user_profile.reload.facts['ai']['email']).to eq(cv_email)
  end

  it 'makes no AI call and leaves facts nil without a default integration' do
    user.update!(default_ai_integration: nil)

    perform

    expect(a_request(:post, gemini_url)).not_to have_been_made
    expect(user_profile.reload.facts).to be_nil
    expect(user_profile.facts_cv_digest).to be_nil
  end
end
