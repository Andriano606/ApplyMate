# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::ApproveReview, type: :operation do
  include_context 'with shared operation spec variables'

  let(:current_user) { create(:user) }
  let(:fields) do
    [ answer_field(id: 'remote', kind: 'radio_group', label: 'Remote?', options: AnswerHelpers::YES_NO),
      answer_field(id: 'why', kind: 'textarea', label: 'Why us?', required: true),
      answer_field(id: 'gdpr', kind: 'checkbox', label: 'I agree to the privacy policy', required: true) ]
  end
  let(:answers) do
    { 'remote' => answer_entry('No', confidence: 0.3), 'why' => answer_entry('Because', confidence: 0.9),
      'gdpr' => answer_entry(true, source: 'policy_pending', confidence: 1.0) }
  end
  let!(:apply) do
    create(:apply, user: current_user, state: :needs_review, stage: 'review', fields: fields.map(&:to_h), answers:,
                   failure: { code: 'review', kind: 'review', detail: 'low_confidence' })
  end
  let(:params) { { id: apply.hashid } }

  before { allow(Apply::TurboHandler::StatusUpdate).to receive(:broadcast) }

  it 'approves with one UPDATE: queued, digest of the answers, reviewed_at, failure cleared' do
    expect { result }.to have_enqueued_job(Apply::Job::Apply).with(apply.id)

    apply.reload
    expect(result).to be_success
    expect(apply).to be_queued
    expect([ apply.stage, apply.failure ]).to eq([ nil, nil ])
    expect(apply.reviewed_at).to be_within(5.seconds).of(Time.current)
    expect(apply.answers_approved_digest).to eq(Apply::Operation::Answer::Digest.call(answers: apply.answers).model)
    expect(apply.job_id).to be_present
    expect(Apply::TurboHandler::StatusUpdate).to have_received(:broadcast).with(apply)
    expect(result.notice[:text]).to eq(I18n.t('apply.approve_review.success'))
  end

  it 'turns every policy_pending answer into a user answer and keeps the rest' do
    result

    expect(apply.reload.answers.transform_values { |answer| answer['source'] }).to eq('remote' => 'ai', 'why' => 'ai', 'gdpr' => 'user')
  end

  it 'stores the edits as user answers and binds the approval to them' do
    params[:answers] = { 'remote' => 'yes', 'why' => 'My own words', 'unknown_field' => 'ignored' }
    result

    expect(apply.reload.answers).to include(
      'remote' => { 'value' => 'Yes', 'source' => 'user', 'confidence' => 1.0 },
      'why' => { 'value' => 'My own words', 'source' => 'user', 'confidence' => 1.0 }
    )
    expect(apply.answers).not_to have_key('unknown_field')
    expect(apply.answers_approved_digest).to eq(Apply::Operation::Answer::Digest.call(answers: apply.answers).model)
  end

  context 'with an optional multiselect and a file field' do
    let(:fields) do
      [ answer_field(id: 'cities', kind: 'multiselect', label: 'Preferred locations',
                     options: [ { 'label' => 'Kyiv' }, { 'label' => 'Remote' } ]),
        answer_field(id: 'cv', kind: 'file', label: 'Resume', semantic: 'cv') ]
    end
    let(:answers) do
      { 'cities' => answer_entry(%w[Kyiv Remote], confidence: 0.9),
        'cv' => answer_entry(Apply::Operation::Answer::FileRef.cv.as_json, source: 'fact', confidence: 1.0) }
    end

    it 'clears the multiselect when only the blank sentinel is posted (every option deselected)' do
      params[:answers] = { 'cities' => [ '' ] }
      result

      expect(result).to be_success
      expect(apply.reload.answers['cities']).to eq('value' => nil, 'source' => 'user', 'confidence' => 1.0)
    end

    it 'keeps the selected options next to the sentinel' do
      params[:answers] = { 'cities' => [ '', 'Remote' ] }
      result

      expect(apply.reload.answers.dig('cities', 'value')).to eq([ 'Remote' ])
    end

    it 'ignores a posted value for a file field' do
      params[:answers] = { 'cv' => Rails.root.join('config/database.yml').to_s }
      result

      expect(apply.reload.answers['cv']).to include('value' => { 'file' => 'cv' }, 'source' => 'fact')
    end
  end

  it 'accepts ActionController::Parameters' do
    params[:answers] = ActionController::Parameters.new('why' => 'Via the form')
    result

    expect(apply.reload.answers.dig('why', 'value')).to eq('Via the form')
  end

  it 'rejects an option that does not exist and changes nothing' do
    params[:answers] = { 'remote' => 'Perhaps' }

    expect { result }.not_to have_enqueued_job(Apply::Job::Apply)
    expect(result.errors[:base]).to eq([ I18n.t('apply.approve_review.invalid_answer', label: 'Remote?') ])
    expect(apply.reload).to be_needs_review
  end

  it 'rejects a blank value for a required field' do
    params[:answers] = { 'why' => '  ' }

    expect(result.errors[:base]).to eq([ I18n.t('apply.approve_review.invalid_answer', label: 'Why us?') ])
    expect(apply.reload).to be_needs_review
  end

  it 'requires the user to fill in a consent that had no affirmative option' do
    apply.update!(answers: answers.merge('gdpr' => answer_entry(nil, source: 'policy_pending', confidence: 0.0)))

    expect(result.errors[:base]).to eq([ I18n.t('apply.approve_review.invalid_answer', label: 'I agree to the privacy policy') ])

    params[:answers] = { 'gdpr' => 'true' }
    expect(described_class.call(params:, current_user:)).to be_success
    expect(apply.reload.answers['gdpr']).to include('value' => true, 'source' => 'user')
  end

  it 'refuses another state with not_allowed' do
    apply.update_columns(state: Apply.states[:cancelled])

    expect(result.errors[:base]).to eq([ I18n.t('apply.approve_review.not_allowed') ])
    expect(apply.reload).to be_cancelled
  end

  it 'loses the race against a concurrent cancel: the guarded UPDATE touches 0 rows' do
    allow(Apply::Operation::Answer::Digest).to receive(:call).and_wrap_original do |original, **args|
      Apply.where(id: apply.id).update_all(state: Apply.states[:cancelled])
      original.call(**args)
    end

    expect { result }.not_to have_enqueued_job(Apply::Job::Apply)
    expect(result.errors[:base]).to eq([ I18n.t('apply.approve_review.not_allowed') ])
    expect(apply.reload).to be_cancelled
  end

  it 'is a 404 for another user\'s apply' do
    other = create(:apply, state: :needs_review)

    expect { described_class.call(params: { id: other.hashid }, current_user:) }.to raise_error(ActiveRecord::RecordNotFound)
  end

  describe 'a duplicate review' do
    before { apply.update!(failure: { code: 'already_applied', kind: 'review', detail: 'abc' }) }

    it 'needs the confirmation' do
      expect(result.errors[:base]).to eq([ I18n.t('apply.approve_review.duplicate_confirmation_required') ])
      expect(apply.reload).to be_needs_review
    end

    it 'stores duplicate_confirmed_at when confirmed' do
      params[:confirm_duplicate] = '1'
      result

      expect(apply.reload).to be_queued
      expect(apply.duplicate_confirmed_at).to be_within(5.seconds).of(Time.current)
    end
  end
end
