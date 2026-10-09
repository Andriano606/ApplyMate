# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Engine::SubmitBaseline do
  let(:ctx) { engine_context(create(:apply)) }
  let(:html) { '<body><h1>Lead</h1><div id="form"><input id="email"></div></body>' }
  let(:final_url) { 'https://acme.example/careers/jobs/1/apply' }
  let(:session) { FakeSession.new(html:, final_url:) }

  subject(:baseline) { described_class.call(ctx:).model }

  before do
    ctx.scratch.platform = Apply::Platform::Generic.new(ctx:, match: ctx.match)
    ctx.open_scope!(:submit, session, 5.minutes.from_now)
    ctx.form_root = ApplyMate::Client::Browser::Target.css('#form')
  end

  it 'is empty on a plain form page, without probing any field' do
    expect(baseline).to eq([])
    expect(session.calls_of(:probe)).to be_empty
  end

  context 'when the page intro thanks the visitor and the URL holds a success fragment' do
    let(:html) { '<body><p>Thank you for your interest in Acme!</p><div id="form"><input id="email"></div></body>' }
    let(:final_url) { 'https://acme.example/success-stories/jobs/1' }

    it 'names the page signals that already hold' do
      expect(baseline).to eq(%w[success_text url_match])
    end
  end
end
