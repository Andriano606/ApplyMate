# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Recipe::Op::Unwrap do
  let(:apply) { create(:apply) }
  let(:ctx) { engine_context(apply) }
  let(:jid) { '20587adf-cf02-473e-8a80-7b009711a2cf' }
  let(:session) { FakeSession.new(html: '', final_url: 'about:blank') }

  before do
    ctx.adopt_match!(Apply::Operation::Engine::Detect::Match.new(
      key: 'ashby', confidence: 0.95, captures: { 'slug' => 'preply', 'jid' => jid }, frame_path: nil, from_alias: false,
      probable: nil
    ))
    ctx.open_scope!(:survey, session, 5.minutes.from_now)
  end

  it "navigates to the platform's canonical form URL" do
    described_class.new(url_template: '{canonical_form_url}').perform!(ctx)

    expect(session.calls_of(:goto)).to eq([ [ "https://jobs.ashbyhq.com/preply/#{jid}/application" ] ])
  end

  it 'marks the platform as unwrapped in this session (ReachForm never opens the canonical URL twice)' do
    2.times { described_class.new(url_template: '{canonical_form_url}').perform!(ctx) }

    expect(ctx.scratch.canonical_unwrapped).to eq([ 'ashby' ])
  end

  it 'is recorded as an unwrap op' do
    expect(described_class.new(url_template: '{canonical_form_url}').to_h).to eq('op' => 'unwrap', 'url_template' => '{canonical_form_url}')
  end
end
