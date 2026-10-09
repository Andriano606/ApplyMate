# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Resume, type: :operation do
  include_context 'with shared operation spec variables'

  let(:current_user) { create(:user) }
  let(:apply)        { create(:apply, :failed, user: current_user) }
  let(:params)       { { id: apply.hashid } }

  before { allow(Apply::TurboHandler::StatusUpdate).to receive(:broadcast) }

  %i[failed needs_human].each do |trait|
    it "re-queues a #{trait} apply, enqueues the job and broadcasts" do
      apply = create(:apply, trait, user: current_user, stage: 'fill_form')
      op = described_class.new(params: { id: apply.hashid }, current_user:)

      expect { op.call }.to have_enqueued_job(Apply::Job::Apply).with(apply.id)

      expect(op.result).to be_success
      expect(apply.reload).to be_queued
      expect(apply.stage).to be_nil
      expect(apply.job_id).to be_present
      expect(apply.failure).to be_present
      expect(Apply::TurboHandler::StatusUpdate).to have_received(:broadcast).with(apply)
      expect(op.result.notice[:text]).to eq(I18n.t('apply.resume.success'))
    end
  end

  it 're-queues an unsupported apply' do
    apply.update_columns(state: Apply.states[:unsupported])

    expect(result).to be_success
    expect(apply.reload).to be_queued
  end

  it 'refuses a submit_unverified apply' do
    apply.update_columns(state: Apply.states[:submit_unverified])

    expect { result }.not_to have_enqueued_job(Apply::Job::Apply)
    expect(result.errors[:base]).to eq([ I18n.t('apply.resume.not_allowed') ])
  end

  it 'refuses a claimed needs_human apply' do
    apply.update_columns(state: Apply.states[:needs_human], submit_claimed_at: Time.current)

    expect(result.errors[:base]).to eq([ I18n.t('apply.resume.not_allowed') ])
    expect(apply.reload).to be_needs_human
  end

  it 'loses gracefully when the apply was claimed concurrently' do
    allow_any_instance_of(Apply).to receive(:resumable?).and_return(true) # rubocop:disable RSpec/AnyInstance
    apply.update_columns(submit_claimed_at: Time.current)

    expect(result.errors[:base]).to eq([ I18n.t('apply.resume.not_allowed') ])
    expect(apply.reload).to be_failed
  end

  it 'refuses when another apply for the vacancy is already active' do
    create(:apply, user: current_user, vacancy: apply.vacancy)

    expect(result.errors[:base]).to eq([ I18n.t('apply.create.already_active') ])
    expect(apply.reload).to be_failed
  end

  context 'when a sibling apply for the vacancy already claimed or submitted' do
    let(:apply) { create(:apply, :failed, user: current_user) }

    %i[completed claimed].each do |trait|
      it "refuses (#{trait} sibling): resuming would send a second application" do
        create(:apply, trait, user: current_user, vacancy: apply.vacancy, source_profile: apply.source_profile)

        expect { result }.not_to have_enqueued_job(Apply::Job::Apply)
        expect(result.errors[:base]).to eq([ I18n.t('apply.resume.already_submitted') ])
        expect(apply.reload).to be_failed
      end
    end

    it 'refuses inside the UPDATE when the sibling submitted after the check' do
      allow_any_instance_of(Apply).to receive(:resumable?).and_return(true) # rubocop:disable RSpec/AnyInstance
      create(:apply, :completed, user: current_user, vacancy: apply.vacancy, source_profile: apply.source_profile)

      expect(result.errors[:base]).to eq([ I18n.t('apply.resume.already_submitted') ])
      expect(apply.reload).to be_failed
    end

    it 'ignores a cancelled sibling' do
      create(:apply, :claimed, state: :cancelled, user: current_user, vacancy: apply.vacancy,
                               source_profile: apply.source_profile)

      expect(result).to be_success
      expect(apply.reload).to be_queued
    end
  end

  it "does not find another user's apply" do
    other = create(:apply, :failed)
    op = described_class.new(params: { id: other.hashid }, current_user:)

    expect { op.call }.to raise_error(ActiveRecord::RecordNotFound)
  end
end
