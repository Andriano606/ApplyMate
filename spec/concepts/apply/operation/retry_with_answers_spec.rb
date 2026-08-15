# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::RetryWithAnswers, type: :operation do
  include_context 'honeytech dou'

  let(:current_user) { user }
  let(:review_fields) do
    [
      { 'handle' => 3, 'name' => 'security_question', 'accessible_name' => 'Скільки років досвіду з Ruby?',
        'tag' => 'input', 'type' => 'text', 'value' => '', 'role' => 'custom_question', 'fingerprint' => 'fp-question' },
      { 'handle' => 4, 'name' => 'phone', 'accessible_name' => 'Телефон',
        'tag' => 'input', 'type' => 'tel', 'value' => '', 'role' => 'phone', 'fingerprint' => 'fp-phone' }
    ]
  end

  let(:params) do
    { id: apply.hashid,
      answers: { 'fp-question' => '6 років', 'fp-phone' => '+380501112233' } }
  end

  before do
    apply.update!(status: :needs_review, error: 'gave up', review_fields: review_fields)
  end

  it 'saves the answers into the bank as manual entries' do
    expect(result).to be_success

    question_entry = user_profile.answer_banks.find_by(role: 'custom_question',
                                                       question: 'скільки років досвіду з ruby?')
    expect(question_entry).to have_attributes(answer: '6 років', source: 'manual')
    expect(user_profile.answer_banks.find_by(role: 'phone'))
      .to have_attributes(answer: '+380501112233', source: 'manual')
  end

  it 'overrides an ai_generated answer for the same role' do
    create(:answer_bank, user_profile:, role: 'phone', answer: 'old', source: :ai_generated)

    expect(result).to be_success
    expect(user_profile.answer_banks.find_by(role: 'phone'))
      .to have_attributes(answer: '+380501112233', source: 'manual')
  end

  it 'resets the apply and re-enqueues the pipeline job' do
    expect(result).to be_success

    reloaded = apply.reload
    expect(reloaded.status).to eq('checking_applyble')
    expect(reloaded.error).to be_nil
    expect(reloaded.review_fields).to be_blank
    expect(Apply::Job::Apply).to have_been_enqueued.with(apply.id)
  end

  it 'skips blank answers' do
    params[:answers]['fp-question'] = ''
    expect(result).to be_success
    expect(user_profile.answer_banks.where(role: 'custom_question')).to be_empty
  end

  context 'when the apply belongs to another user' do
    let(:current_user) do
      User.create!(email: 'other@example.com', name: 'Other',
                   provider: 'google_oauth2', uid: 'uid-other')
    end

    it 'denies access' do
      expect { result }.to raise_error(Pundit::NotAuthorizedError)
    end
  end
end
