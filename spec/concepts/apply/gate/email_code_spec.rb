# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Gate::EmailCode do
  let(:ctx) { engine_context(create(:apply)) }
  let(:evidence) { Apply::Operation::Engine::Detect::Evidence.empty }
  let(:code_page) { { outline: [ 'h1 Verify', 'p Enter the verification code we sent to your email.' ] } }

  before { allow(Apply::Operation::Engine::AwaitInput).to receive(:call) }

  def check(frames:, elements: [])
    described_class.new.call(ctx, event: :after_submit, snapshot: build_snapshot(frames:, elements:), evidence:)
  end

  it 'listens after the submit click only' do
    expect(described_class.events).to eq([ :after_submit ])
  end

  it 'awaits the code when the page asks for it and has a one-time-code input' do
    element = snapshot_element(role: 'textbox', name: 'Code', type: 'text', attrs: { 'autocomplete' => 'one-time-code' })

    expect(check(frames: [ code_page ], elements: [ element ])).to be(true)
    expect(Apply::Operation::Engine::AwaitInput).to have_received(:call)
      .with(ctx:, kind: 'email_code', field_element: hash_including('name' => 'Code'), frame: hash_including('ref' => 'f0'))
  end

  it 'recognizes the input by its name' do
    element = snapshot_element(role: 'textbox', name: 'Verification', type: 'text')
    element['attrs'] = element['attrs'].merge('name' => 'otp')

    expect(check(frames: [ code_page ], elements: [ element ])).to be(true)
  end

  it 'reads the Ukrainian wording' do
    element = snapshot_element(role: 'textbox', name: 'Код', type: 'text', attrs: { 'autocomplete' => 'one-time-code' })

    expect(check(frames: [ { alerts: [ 'Введіть код підтвердження' ] } ], elements: [ element ])).to be(true)
  end

  it 'ignores a thank-you page' do
    expect(check(frames: [ { outline: [ 'h1 Thank you for applying' ] } ])).to be_nil
    expect(Apply::Operation::Engine::AwaitInput).not_to have_received(:call)
  end

  it 'ignores the wording without a code input, and an unrelated input' do
    other = snapshot_element(role: 'textbox', name: 'Email', type: 'email')

    expect(check(frames: [ code_page ])).to be_nil
    expect(check(frames: [ code_page ], elements: [ other ])).to be_nil
  end
end
