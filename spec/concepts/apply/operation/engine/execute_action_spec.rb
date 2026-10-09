# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Engine::ExecuteAction do
  subject(:run) { described_class.call(ctx:, action:, snapshot:, **options) }

  let(:job) { 'https://acme.example/jobs/1' }
  let(:apply) { create(:apply, entry_url: job) }
  let(:ctx) { engine_context(apply) }
  let(:options) { {} }
  let(:session) { FakeSession.new(html: '', final_url: job, snapshot:) }
  # f0:e0 Apply tab, f0:e1 a careers link, f0:e2 an intranet link, f0:e3 a Google sign-in link, f0:e4 the send
  # button, f0:e5 a password field, f0:e6 a name field, f0:e7 a div button "Send application" the probe did not call
  # submit_like, f0:e8 a dialog's type=button "Відгукнутися" next to f0:e9 (a field of that dialog), f0:e10 the page's
  # "Відгукнутися" launcher, f0:e11 a link "Submit your CV" that leads to the form
  let(:snapshot) do
    build_snapshot(frames: [ { url: job } ], elements: [
      snapshot_element(role: 'tab', name: 'Apply'),
      snapshot_element(role: 'link', name: 'Careers', href: '/careers/apply'),
      snapshot_element(role: 'link', name: 'Intranet', href: 'http://192.168.1.10/admin'),
      snapshot_element(role: 'link', name: 'Sign in with Google', href: 'https://accounts.google.com/o/oauth2/auth'),
      snapshot_element(role: 'button', name: 'Send application', submit_like: true),
      snapshot_element(name: 'Password', type: 'password', visible: false), # hidden: SignInWall halts on a visible one
      snapshot_element(name: 'Full name'),
      snapshot_element(role: 'button', name: 'Send application', tag: 'div'),
      snapshot_element(role: 'button', name: 'Відгукнутися', scope: 'dialog'),
      snapshot_element(name: 'Email', type: 'email', scope: 'dialog'),
      snapshot_element(role: 'button', name: 'Відгукнутися'),
      snapshot_element(role: 'link', name: 'Submit your CV', href: '/careers/1/apply')
    ])
  end
  let(:element) { ->(index) { snapshot.elements[index] } }
  # Everything a rejected action must never call.
  let(:acting) { %i[click press scroll_into_view goto switch_to wait_until fill type select set_checked upload] }

  def action_of(type, ref: nil, key: nil, index: nil, max_ms: nil)
    { 'type' => type, 'ref' => ref, 'key' => key, 'index' => index, 'max_ms' => max_ms }
  end

  def acted
    session.calls.map(&:first) & acting
  end

  before { ctx.open_scope!(:survey, session, 10.minutes.from_now) }

  describe 'rejections (no session action, traced action_rejected)' do
    {
      'a hallucinated ref' => [ { 'type' => 'click', 'ref' => 'f9:e99' }, 'unknown_ref' ],
      'a page-level scroll on a frame ref (preply: scroll f0)' => [ { 'type' => 'scroll', 'ref' => 'f0' }, 'frame_ref' ],
      'a click on a submit_like button' => [ { 'type' => 'click', 'ref' => 'f0:e4' }, 'submit_like' ],
      'a click on a div button named "Send application" (not submit_like)' => [ { 'type' => 'click', 'ref' => 'f0:e7' }, 'submit_like' ],
      'a press on a div button named "Send application"' => [ { 'type' => 'press', 'ref' => 'f0:e7', 'key' => 'Enter' }, 'submit_like' ],
      'a click on a respond verb inside a dialog with fields' => [ { 'type' => 'click', 'ref' => 'f0:e8' }, 'submit_like' ],
      'a click on a password field' => [ { 'type' => 'click', 'ref' => 'f0:e5' }, 'password' ],
      'a press of a key outside the vocabulary' => [ { 'type' => 'press', 'ref' => 'f0:e0', 'key' => 'a' }, 'unknown_key' ],
      'Enter in a fillable field (implicit submit)' => [ { 'type' => 'press', 'ref' => 'f0:e6', 'key' => 'Enter' }, 'implicit_submit' ],
      'navigate to a private address' => [ { 'type' => 'navigate', 'ref' => 'f0:e2' }, 'private_address' ],
      'navigate to a sign-in host' => [ { 'type' => 'navigate', 'ref' => 'f0:e3' }, 'sign_in_host' ],
      'navigate on an element without href' => [ { 'type' => 'navigate', 'ref' => 'f0:e0' }, 'no_href' ],
      'switch_tab outside the open tabs' => [ { 'type' => 'switch_tab', 'index' => 3 }, 'unknown_tab' ],
      'a type outside the closed vocabulary' => [ { 'type' => 'fill', 'ref' => 'f0:e6' }, 'action_not_allowed' ]
    }.each do |label, (given, reason)|
      context "with #{label}" do
        let(:action) { action_of(given['type'], **given.except('type').symbolize_keys) }

        it "rejects it as #{reason}" do
          expect(run.model).to eq([])
          expect(run).to have_attributes(success?: true)
          expect(run[:rejected]).to eq(reason)
          expect(run[:page_changed]).to be(false)
          expect(run[:snapshot]).to be(snapshot)
          expect(acted).to be_empty
          expect(ctx.scratch.trace.last).to include('event' => 'action_rejected', 'reason' => reason)
        end
      end
    end

    context 'with switch_tab to a sign-in tab' do
      let(:session) { FakeSession.new(html: '', final_url: job, snapshot:, pages: [ job, 'https://accounts.google.com/signin' ]) }
      let(:action) { action_of('switch_tab', index: 1) }

      it 'rejects it as sign_in_host' do
        expect(run[:rejected]).to eq('sign_in_host')
        expect(acted).to be_empty
      end
    end

    context 'with a type the caller does not allow' do
      let(:action) { action_of('scroll', ref: 'f0:e0') }
      let(:options) { { allowed: %w[click] } }

      it 'rejects it as action_not_allowed' do
        expect(run[:rejected]).to eq('action_not_allowed')
        expect(acted).to be_empty
      end
    end
  end

  # A send verb on the page itself, with every field inside a dialog / form scope, is the launcher that opens the
  # modal form (`<button type=button data-toggle=modal>Надіслати резюме</button>`): clickable.
  context 'with a send-verb launcher outside any scope' do
    let(:snapshot) do
      build_snapshot(frames: [ { url: job } ], elements: [
        snapshot_element(role: 'button', name: 'Надіслати резюме'),
        snapshot_element(role: 'textbox', name: 'Search jobs', search_like: true),
        snapshot_element(name: 'Email', type: 'email', scope: 'form@1'),
        snapshot_element(role: 'button', name: 'Apply', scope: 'form@2')
      ])
    end

    it 'clicks the send-verb launcher' do
      result = described_class.call(ctx:, action: action_of('click', ref: 'f0:e0'), snapshot:)

      expect(result[:rejected]).to be_nil
      expect(session.calls_of(:click).map(&:first)).to eq([ element[0]['target'] ])
    end

    it "clicks an apply launcher in an id-less form apart from another form's fields" do
      result = described_class.call(ctx:, action: action_of('click', ref: 'f0:e3'), snapshot:)

      expect(result[:rejected]).to be_nil
    end
  end

  context 'with a click' do
    let(:action) { action_of('click', ref: 'f0:e0') }
    let(:next_page) { build_snapshot(frames: [ { url: job } ], elements: [ snapshot_element(role: 'tab', name: 'Apply', selected: true) ]) }

    it 'clicks the target and returns the click op and a fresh snapshot' do
      session.on(:click) { session.show(next_page) }

      expect(run.model).to eq([ Apply::Recipe::Op::Click.new(target: element[0]['target']).to_h ])
      expect(session.calls_of(:click).map(&:first)).to eq([ element[0]['target'] ])
      expect(run[:rejected]).to be_nil
      expect(run[:snapshot]).to be(next_page)
      expect(run[:page_changed]).to be(true)
    end

    it 'reports no change when the page stayed the same, after one bounded second look' do
      expect(run[:page_changed]).to be(false)
      expect(run[:navigated]).to be(false)
      expect(session.calls_of(:wait_until).sole.sole[:timeout]).to eq(described_class::SECOND_LOOK_SECONDS)
    end

    it 'sees a change that renders after the click settled (a modal fading in) on the second look' do
      session.on(:wait_until) { session.show(next_page) }

      expect(run[:page_changed]).to be(true)
      expect(run[:snapshot]).to be(next_page)
    end

    it 'reports a delayed JS redirect during the second look as a navigation' do
      session.on(:wait_until) { session.show(snapshot, url: 'https://acme.example/jobs/1/apply') }

      expect(run[:navigated]).to be(true)
      expect(run[:page_changed]).to be(true)
    end

    it 'keeps the post-click snapshot when no second-look snapshot succeeds' do
      allow(session).to receive(:wait_until).and_return(false)

      expect(run[:snapshot]).to be(snapshot)
      expect(run[:page_changed]).to be(false)
    end

    it 'adopts a tab the click opened (Engine::AdoptNewTab) and records the switch' do
      session.on(:click) { session.open_page('https://ats.example/apply') }

      expect(run.model.map { |op| op['op'] }).to eq(%w[click switch_tab])
      expect(session.calls_of(:switch_to)).to eq([ [ 1 ] ])
      expect(run[:page_changed]).to be(true)
    end

    it 'rejects a target that disappeared before the click as target_not_found' do
      session.on(:click) { |target| raise ApplyMate::Client::Browser::TargetNotFound, target }

      expect(run[:rejected]).to eq('target_not_found')
      expect(run.model).to eq([])
    end
  end

  context 'with the apply / respond verb outside any dialog or form (the page launcher)' do
    let(:action) { action_of('click', ref: 'f0:e10') }

    it 'clicks it' do
      expect(run[:rejected]).to be_nil
      expect(session.calls_of(:click).map(&:first)).to eq([ element[10]['target'] ])
    end
  end

  context 'with a send verb on a link that navigates' do
    let(:action) { action_of('click', ref: 'f0:e11') }

    it 'clicks it: following an href never submits a form' do
      expect(run[:rejected]).to be_nil
      expect(session.calls_of(:click).map(&:first)).to eq([ element[11]['target'] ])
    end
  end

  context 'with a press' do
    let(:action) { action_of('press', ref: 'f0:e0', key: 'ArrowDown') }

    it 'presses the key on the target' do
      expect(run.model).to eq([ Apply::Recipe::Op::Press.new(target: element[0]['target'], key: 'ArrowDown').to_h ])
      expect(session.calls_of(:press)).to eq([ [ element[0]['target'], 'ArrowDown' ] ])
    end
  end

  context 'with a scroll' do
    let(:action) { action_of('scroll', ref: 'f0:e6') }

    it 'scrolls the target into view' do
      expect(run.model.sole).to include('op' => 'scroll')
      expect(session.calls_of(:scroll_into_view).map(&:first)).to eq([ element[6]['target'] ])
    end
  end

  context 'with a navigate' do
    let(:action) { action_of('navigate', ref: 'f0:e1') }
    let(:careers) { 'https://acme.example/careers/apply' }

    before do
      resolution = ApplyMate::Net::Operation::ResolvePublicAddress::Resolution.new(url: careers, host: 'acme.example', port: 443,
                                                                                 ip: '93.184.216.34')
      allow(ApplyMate::Net::Operation::ResolvePublicAddress).to receive(:call).with(url: careers)
                                                                              .and_return(instance_double(ApplyMate::Operation::Result, model: resolution))
    end

    it 'opens the absolute href and records a click on the link, never the URL' do
      expect(run.model).to eq([ Apply::Recipe::Op::Click.new(target: element[1]['target']).to_h ])
      expect(session.calls_of(:goto)).to eq([ [ careers ] ])
      expect(run.model.to_json).not_to include('careers/apply')
    end
  end

  context 'with a switch_tab' do
    let(:session) { FakeSession.new(html: '', final_url: job, snapshot:, pages: [ job, 'https://ats.example/apply' ]) }
    let(:action) { action_of('switch_tab', index: 1) }

    it 'switches and records the op' do
      expect(run.model).to eq([ { 'op' => 'switch_tab', 'index' => 1 } ])
      expect(session.calls_of(:switch_to)).to eq([ [ 1 ] ])
      expect(run[:navigated]).to be(true)
    end
  end

  context 'with a wait' do
    let(:action) { action_of('wait', max_ms: 60_000) }

    it 'clamps max_ms to MAX_WAIT_MS and records nothing' do
      expect(run.model).to eq([])
      expect(session.calls_of(:wait_until).sole.sole[:timeout]).to eq(described_class::MAX_WAIT_MS / 1000.0)
      expect(run[:rejected]).to be_nil
    end
  end
end
