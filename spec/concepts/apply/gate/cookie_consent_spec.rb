# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Gate::CookieConsent do
  let(:ctx) { engine_context(create(:apply)).tap { |context| context.session = session } }
  let(:session) { FakeSession.new(html: '', final_url: 'https://jobs.example.com') }
  let(:evidence) { Apply::Operation::Engine::Detect::Evidence.empty }

  def button(name, css, visible: true, disabled: false, role: 'button')
    { 'role' => role, 'name' => name, 'visible' => visible, 'disabled' => disabled,
      'target' => ApplyMate::Client::Browser::Target.css(css) }
  end

  def snapshot(*elements)
    ApplyMate::Client::Browser::Snapshot.new(frames: [ { 'captcha' => [] } ], elements:,
                                             evidence: { frame_urls: [], script_srcs: [], iframe_srcs: [],
                                                         dom_markers: {} }, digest: '')
  end

  def check(snap)
    described_class.new.call(ctx, event: :after_goto, evidence:, snapshot: snap)
  end

  let(:banner) do
    snapshot(button('Accept all cookies', '#all'), button('Only necessary', '#necessary'),
             button('Apply for this job', '#apply'))
  end

  it 'clicks the least-consent choice, settles and traces it' do
    expect(check(banner)).to be(true)

    expect(session.calls).to eq([ [ :click, ApplyMate::Client::Browser::Target.css('#necessary') ], [ :settle, :click ] ])
    expect(ctx.scratch.trace.last).to include('event' => 'cookie_consent', 'button' => 'Only necessary')
  end

  it 'understands Ukrainian banners' do
    check(snapshot(button('Прийняти все', '#all'), button('Лише необхідні', '#ua')))

    expect(session.calls_of(:click)).to eq([ [ ApplyMate::Client::Browser::Target.css('#ua') ] ])
  end

  it "accepts all only when the banner offers nothing else" do
    check(snapshot(button('Accept all', '#all'), button('Settings', '#settings')))

    expect(session.calls_of(:click)).to eq([ [ ApplyMate::Client::Browser::Target.css('#all') ] ])
  end

  it 'skips hidden, disabled and long-text buttons and pages without a banner' do
    expect(check(snapshot(button('Reject all', '#hidden', visible: false), button('Reject all', '#off', disabled: true),
                          button("Accept all cookies and #{'x' * 80}", '#long'), button('Submit', '#submit'))))
      .to be_nil
    expect(session.calls).to be_empty
  end

  it 'clicks at most MAX_CLICKS times per session' do
    3.times { check(banner) }

    expect(session.calls_of(:click).size).to eq(described_class::MAX_CLICKS)
  end

  it 'gets a fresh budget with a new session' do
    3.times { check(banner) }
    ctx.session = session

    expect(check(banner)).to be(true)
  end

  it 'never raises: a vanished button is traced and left for the next event' do
    gone = FakeSession.new(html: '', final_url: 'https://jobs.example.com', missing: [ '#necessary' ])
    ctx.session = gone

    expect(check(banner)).to be_nil
    expect(ctx.scratch.trace.last).to include('event' => 'cookie_consent_failed')
  end

  it 'does nothing without an open session or a snapshot' do
    ctx.session = nil

    expect(check(banner)).to be_nil
    expect(described_class.new.call(ctx, event: :after_goto, evidence:, snapshot: nil)).to be_nil
  end
end
