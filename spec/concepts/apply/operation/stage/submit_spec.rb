# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Stage::Submit do
  let(:apply) { create(:apply) }
  let(:ctx) { engine_context(apply) }
  let(:step_record) { create(:apply_step, apply:, attempt: ctx.attempt, stage: 'submit') }
  let(:elements) { [ button('Submit Application', submit_like: true), button('Upload file') ] }
  let(:frames) { [ { 'url' => 'https://jobs.ashbyhq.com/preply/x/application' } ] }
  let(:snapshot) { FakeSession::EMPTY_SNAPSHOT.with(frames:, elements:) }
  let(:session) { FakeSession.new(html: '', final_url: 'https://jobs.ashbyhq.com/preply/x/application', snapshot:) }
  let(:deadline) { 5.minutes.from_now }
  let(:submit_target) { ApplyMate::Client::Browser::Target.css('#submit-application') }

  def button(name, submit_like: false, regions: [ '#form' ], visible: true, disabled: false)
    { 'ref' => name, 'tag' => 'button', 'type' => 'button', 'name' => name, 'submit_like' => submit_like,
      'visible' => visible, 'disabled' => disabled, 'regions' => regions,
      'target' => ApplyMate::Client::Browser::Target.css("##{name.parameterize}") }
  end

  def submit!
    described_class.call(ctx:)
  end

  def call_names
    session.calls.map(&:first)
  end

  before do
    ctx.adopt_match!(Apply::Operation::Engine::Detect::Match.new(
      key: 'ashby', confidence: 0.95, captures: { 'slug' => 'preply', 'jid' => '20587adf-cf02-473e-8a80-7b009711a2cf' },
      frame_path: nil, from_alias: false, probable: nil
    ))
    ctx.form_root = ApplyMate::Client::Browser::Target.css('#form')
    ctx.scratch.step_record = step_record
    ctx.open_scope!(:submit, session, deadline)
  end

  it 'has a localized stage name' do
    expect(I18n.t("apply.stage.#{described_class.stage}", locale: :uk)).to be_present
    expect(I18n.t("apply.stage.#{described_class.stage}", locale: :en)).to be_present
  end

  it 'watches the submit request, captures the artifact, claims, marks the network and only then clicks' do
    claimed_at_click = nil
    session.on(:click) { claimed_at_click = Apply.find(apply.id).submit_claimed_at }

    expect(submit![:step_result]).to eq('button' => 'Submit Application')
    expect(claimed_at_click).to be_present
    expect(session.calls_of(:click)).to eq([ [ submit_target ] ])
    expect(session.calls_of(:network_watch)).to eq([ [ ctx.platform.success_evidence.dig(:submit_request, :url) ] ])
    expect(session.calls_of(:trial_click)).to eq([ [ submit_target ] ])
    order = %i[trial_click network_watch screenshot network_mark click settle].map { |name| call_names.index(name) }
    expect(order).to eq(order.sort)
    expect(session.calls_of(:settle)).to eq([ [ :submit ] ])
    expect(ctx.scratch.claim_mark).to eq(0)
    expect(step_record.artifacts.map { |artifact| artifact.filename.to_s }).to eq([ 'before_submit.png' ])
  end

  it 'takes the claim after the artifact (a failing screenshot never blocks the submit)' do
    allow(session).to receive(:screenshot).and_raise(RuntimeError, 'page closed')

    submit!

    expect(apply.reload.submit_claimed_at).to be_present
    expect(session.calls_of(:click).size).to eq(1)
  end

  it 'runs the after_submit gates on a fresh snapshot' do
    allow(Apply::Operation::Engine::RunGates).to receive(:call).and_call_original

    submit!

    expect(Apply::Operation::Engine::RunGates).to have_received(:call).with(ctx:, event: :before_submit, snapshot:).ordered
    expect(Apply::Operation::Engine::RunGates).to have_received(:call).with(ctx:, event: :after_submit, snapshot:).ordered
  end

  shared_examples 'a halt before the claim' do |code|
    it "halts #{code} without claiming or clicking" do
      expect { submit! }.to raise_error(Apply::Operation::Engine::Halt) { |halt| expect(halt.code).to eq(code) }
      expect(apply.reload.submit_claimed_at).to be_nil
      expect(session.calls_of(:click)).to be_empty
      expect(session.calls_of(:network_mark)).to be_empty
    end
  end

  context 'without a submit button in the form root' do
    let(:elements) { [ button('Submit Application', submit_like: true, regions: []), button('Next') ] }

    it_behaves_like 'a halt before the claim', :target_not_found
  end

  context 'with two submit buttons in the form root' do
    let(:elements) { [ button('Submit Application', submit_like: true), button('Send', submit_like: true) ] }

    it_behaves_like 'a halt before the claim', :target_not_found
  end

  context 'when the only submit button is hidden or disabled' do
    let(:elements) do
      [ button('Submit Application', submit_like: true, visible: false), button('Send', submit_like: true, disabled: true) ]
    end

    it_behaves_like 'a halt before the claim', :target_not_found
  end

  context 'with less than SUBMIT_RESERVE seconds left' do
    let(:deadline) { (described_class::SUBMIT_RESERVE - 10).seconds.from_now }

    it_behaves_like 'a halt before the claim', :deadline

    it 'does not even look at the page' do
      expect { submit! }.to raise_error(Apply::Operation::Engine::Halt)
      expect(session.calls_of(:snapshot_all)).to be_empty
    end
  end

  context 'when a visible captcha shows before the submit' do
    let(:frames) { [ { 'url' => 'https://jobs.ashbyhq.com/preply/x/application', 'captcha' => [ 'recaptcha' ] } ] }

    it_behaves_like 'a halt before the claim', :manual_apply_required

    it 'asks the user to apply themselves' do
      expect { submit! }.to raise_error(Apply::Operation::Engine::Halt) { |halt| expect(halt.detail).to eq(:captcha) }
    end
  end

  context 'when something covers the submit button (the trial click is obstructed twice)' do
    before do
      allow(session).to receive(:trial_click)
        .and_raise(ApplyMate::Client::Browser::Obstructed.new(submit_target, 'intercepts pointer events'))
    end

    it_behaves_like 'a halt before the claim', :target_obstructed

    it 'retried once after the gates' do
      expect { submit! }.to raise_error(Apply::Operation::Engine::Halt)
      expect(session).to have_received(:trial_click).twice
    end
  end

  context 'when another apply already holds the claim' do
    before { apply.update_columns(submit_claimed_at: 1.minute.ago) }

    it 'never clicks' do
      expect { submit! }.to raise_error(Apply::Operation::Engine::Halt) { |halt| expect(halt.code).to eq(:already_claimed) }
      expect(session.calls_of(:click)).to be_empty
    end
  end
end
