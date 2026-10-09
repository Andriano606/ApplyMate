# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Recipe::Op::Scroll do
  let(:apply) { create(:apply) }
  let(:ctx) { engine_context(apply) }
  let(:target) { ApplyMate::Client::Browser::Target.css('#apply-section') }
  let(:session) { FakeSession.new(html: '', final_url: 'https://acme.example/jobs/1') }

  before { ctx.open_scope!(:survey, session, 5.minutes.from_now) }

  it 'round-trips through its hash' do
    hash = { 'op' => 'scroll', 'target' => target.to_h }

    expect(Apply::Recipe::Op::Base.parse!(JSON.parse(hash.to_json)).to_h).to eq(hash)
  end

  it 'scrolls the target into view and settles for a key' do
    described_class.new(target:).perform!(ctx)

    expect(session.calls).to eq([ [ :scroll_into_view, target ], [ :settle, :key ] ])
  end
end
