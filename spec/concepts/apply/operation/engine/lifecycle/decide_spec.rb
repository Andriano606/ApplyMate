# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Engine::Lifecycle::Decide do
  def decide(apply, code, auto_resume: true, **halt_options)
    halt = Apply::Operation::Engine::Halt.new(code, **halt_options)
    described_class.call(apply:, halt:, stage: 'fake_submit', auto_resume:, extra: {}).model
  end

  let(:apply) { create(:apply, :running, attempt: 3) }
  let(:claimed) { create(:apply, :running, submit_claimed_at: Time.current) }

  it 'takes the halt state and builds the uniform failure hash with a redacted detail' do
    decision = decide(apply, :no_application_path, detail: "no button for #{apply.user.email}")

    expect(decision).to have_attributes(state: :unsupported, auto_resume: false, release_claim: false)
    expect(decision.failure).to eq(code: :no_application_path, kind: :unsupported, stage: 'fake_submit',
                                   detail: 'no button for {{fact.email}}', after_claim: false, attempt: 3)
    expect(decision.attributes).to eq(state: Apply.states[:unsupported], failure: decision.failure, stage: nil,
                                            input_request: nil)
  end

  describe 'claim rule' do
    it 'turns any halt after the claim into submit_unverified, keeping the code' do
      decision = decide(claimed, :unexpected_error)

      expect(decision).to have_attributes(state: :submit_unverified, release_claim: false)
      expect(decision.failure).to include(code: :unexpected_error, after_claim: true)
      expect(decision.attributes).not_to have_key(:submit_claimed_at)
    end

    it 'releases the claim only for a definitive claim-releasing code' do
      decision = decide(claimed, :validation_rejected, definitive: true)

      expect(decision).to have_attributes(state: :failed, release_claim: true)
      expect(decision.attributes).to include(submit_claimed_at: nil)
      expect(decide(claimed, :validation_rejected)).to have_attributes(state: :submit_unverified)
    end

    it 'never auto-resumes a claimed apply' do
      expect(decide(claimed, :worker_lost)).to have_attributes(state: :submit_unverified, auto_resume: false)
    end
  end

  describe 'auto-resume once' do
    it 're-queues the first transient halt and flags it' do
      decision = decide(apply, :worker_lost)

      expect(decision).to have_attributes(state: :queued, auto_resume: true)
      expect(decision.failure).to include(auto_resumed: true)
    end

    it 'fails the second transient halt and carries the flag' do
      apply.update!(failure: { 'code' => 'worker_lost', 'auto_resumed' => true })

      decision = decide(apply, :deadline)
      expect(decision).to have_attributes(state: :failed, auto_resume: false)
      expect(decision.failure).to include(auto_resumed: true)
    end

    it 'does not re-queue a permanent halt or when the caller disables it' do
      expect(decide(apply, :unexpected_error)).to have_attributes(state: :failed, auto_resume: false)
      expect(decide(apply, :worker_lost, auto_resume: false)).to have_attributes(state: :failed, auto_resume: false)
    end
  end

  it 'merges the caller extras into the failure' do
    halt = Apply::Operation::Engine::Halt.new(:human_timeout)
    decision = described_class.call(apply:, halt:, extra: { previous: { 'code' => 'captcha_challenge' } }).model

    expect(decision.failure).to include(code: :human_timeout, stage: nil, previous: { 'code' => 'captcha_challenge' })
  end
end
