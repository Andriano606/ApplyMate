# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ApplyMate::Client::Browser::Session do
  let(:target) { ApplyMate::Client::Browser::Target }

  describe '.owner_for' do
    it 'tags leases with the hostname prefix, the pid and the apply hashid' do
      apply = build_stubbed(:apply)

      expect(described_class.owner_for(apply))
        .to eq("#{ApplyMate::Client::Browser::Browserd.owner_prefix}#{Process.pid}:#{apply.hashid}")
    end
  end

  describe 'against browserd', :browser do
    let(:owner) { "#{ApplyMate::Client::Browser::Browserd.owner_prefix}#{Process.pid}:session-spec" }

    def open_session(**options, &)
      described_class.open(deadline: 2.minutes.from_now, owner:, **options, &)
    end

    def browserd_health
      JSON.parse(Faraday.get("#{ApplyMate::Client::Browser::Browserd.url}/health").body)
    end

    # Leases still tagged with this example's owner (the sweep releases them, so it also cleans up). Scoped to the
    # owner: other workspaces may share the browserd-test container.
    def leftover_leases
      ApplyMate::Client::Browser::Operation::ReleaseOrphanLeases.call(owner_prefix: owner).model
    end

    it 'navigates to a page and reads it back' do
      open_session do |session|
        nav = session.goto(FixtureSite.url('/form.html'))

        expect(nav).to have_attributes(status: 200, final_url: FixtureSite.url('/form.html'),
                                       was_challenge: false, challenge_passed: true)
        expect(session.current_url).to eq(FixtureSite.url('/form.html'))
        expect(session.html).to include('Apply for Ruby Developer')
        expect(session.cookies).to eq('fixture_session=abc123')
        expect(session.frames).to eq([ { 'url' => FixtureSite.url('/form.html'), 'name' => '' } ])
        expect(session.settle_content).to be(true)
        expect(session.screenshot(full_page: true)).to start_with("\x89PNG".b)
      end
    end

    it 'fills controls and reads their values back with the read_value probe' do
      open_session do |session|
        session.goto(FixtureSite.url('/form.html'))

        session.fill(target.css('#full_name'), 'Jane Doe')
        session.fill(target.css('#cover'), 'Hello')
        session.press(target.css('#cover'), 'End')
        session.press(target.css('#cover'), '!')
        session.select(target.css('#experience'), label: '5+ years')
        session.set_checked(target.css('#consent'), true)
        session.set_checked(target.css('#relocate_no'), true)

        values = %w[#full_name #cover #experience #consent #relocate_no #relocate_yes].to_h do |selector|
          [ selector, session.probe(:read_value, target.css(selector)) ]
        end
        expect(values['#full_name']).to include('tag' => 'input', 'value' => 'Jane Doe')
        expect(values['#cover']).to include('tag' => 'textarea', 'value' => 'Hello!')
        expect(values['#experience']).to include('value' => 'senior', 'text' => '5+ years')
        expect(values.values_at('#consent', '#relocate_no', '#relocate_yes').pluck('checked')).to eq([ true, true, false ])
      end
    end

    it 'uploads into a visually hidden file input (:attached) or through the dropzone file chooser' do
      Dir.mktmpdir do |dir|
        cv, letter = %w[cv.pdf letter.pdf].map { |name| File.join(dir, name).tap { |path| File.binwrite(path, '%PDF') } }

        open_session do |session|
          session.goto(FixtureSite.url('/form.html'))
          session.upload(target.css('#cv'), cv)
          expect(session.probe(:read_value, target.css('#cv'))['files']).to eq([ 'cv.pdf' ])

          session.upload(target.css('label.dropzone'), letter, via_chooser: true)
          session.settle(:file)
          expect(session.probe(:read_value, target.css('#cv'))['files']).to eq([ 'letter.pdf' ])
        end
      end
    end

    it 'submits with a has_text target, settles and sees the POST in the network log' do
      open_session do |session|
        session.goto(FixtureSite.url('/form.html'))
        session.fill(target.css('#email'), 'jane@example.com')
        expect(session.present?(target.css('button[type=submit]'), visibility: :required)).to be(false) # 2 match

        mark = session.network_mark
        session.click(target.css('button[type=submit]', has_text: 'Submit application'))
        settle = session.settle(:submit)

        expect(settle).to include(quiet: true)
        expect(session.html).to include('Thank you for applying')
        expect(session.network_since(mark))
          .to include(a_hash_including(method: 'POST', url: FixtureSite.url('/submit'), status: 200))
      end
    end

    it 'resolves targets inside an iframe by selector and by url hops' do
      open_session do |session|
        session.goto(FixtureSite.url('/iframe.html'))
        session.settle_content
        by_selector = [ { 'selector' => 'iframe#embed' } ]

        session.fill(target.css('#email', frame_path: by_selector), 'frame@example.com')

        by_url = target.css('#email', frame_path: [ { 'url_contains' => '/form.html' } ])
        expect(session.probe(:read_value, by_url)['value']).to eq('frame@example.com')
        expect(session.html(frame_path: by_selector)).to include('Apply for Ruby Developer')
        expect(session.html).not_to include('Apply for Ruby Developer')
        expect(session.probe(:snapshot, target.css('form#apply', frame_path: by_selector)))
          .to include(a_hash_including('tag' => 'input', 'id' => 'email', 'label' => 'Email', 'visible' => true))
      end
    end

    it 'waits for a form that renders late after a click' do
      open_session do |session|
        session.goto(FixtureSite.url('/trigger.html'))
        form = target.css('form#late-form')
        expect(session.ready?(form, timeout: 0.3)).to be(false)

        session.click(target.css('button', has_text: 'Apply now'))
        session.settle(:click)

        expect(session.ready?(form, min_fields: 2, timeout: 10)).to be(true)
      end
    end

    it 'stops waiting at once when the root target matches several elements' do
      open_session do |session|
        session.goto(FixtureSite.url('/form.html')) # form#apply and form#newsletter
        started = ApplyMate::Client::Browser::Clock.now_ms

        expect(session.ready?(target.css('form'), timeout: 10)).to be(false)
        expect(ApplyMate::Client::Browser::Clock.now_ms - started).to be < 2_000
        expect(session.ready?(target.css('form#apply'), timeout: 10)).to be(true)
      end
    end

    it 'waits out a Cloudflare-style interstitial' do
      open_session do |session|
        nav = session.goto(FixtureSite.url('/challenge.html'))

        expect(nav).to have_attributes(was_challenge: true, challenge_passed: true, status: 200)
        expect(session.html).to include('looking for an engineer')
      end
    end

    it 'raises TargetNotFound when a target matches several elements' do
      open_session do |session|
        session.goto(FixtureSite.url('/multi.html'))

        expect { session.click(target.css('button.apply')) }
          .to raise_error(ApplyMate::Client::Browser::TargetNotFound) { |error| expect(error.target.strategies.first['css']).to eq('button.apply') }
        expect(session.present?(target.css('button.apply', nth: 1), visibility: :required)).to be(true)
      end
    end

    it 'refuses a private address before navigating' do
      open_session do |session|
        expect { session.goto('http://127.0.0.1:1/') }
          .to raise_error(ApplyMate::Net::UnsafeUrlError) { |error| expect(error.reason).to eq(:private) }
        expect(session.current_url).to eq('about:blank')
      end
    end

    it 'raises PoolBusy when every slot is leased' do
      allow(ApplyMate::Client::Browser::Clock).to receive(:sleep_ms) # skip the Retry-After waits between busy POSTs
      holders = []
      open_session do
        (browserd_health.fetch('max') - 1).times do
          holders << ApplyMate::Client::Browser::Operation::AcquireLease.call(owner:).model
        end

        expect { open_session { raise 'must not run' } }.to raise_error(ApplyMate::Client::Browser::PoolBusy)
        expect(ApplyMate::Client::Browser::Clock).to have_received(:sleep_ms)
          .exactly(ApplyMate::Client::Browser::Operation::AcquireLease::BUSY_ATTEMPTS - 1).times
      end
    ensure
      holders.each { |lease| ApplyMate::Client::Browser::Operation::ReleaseLease.call(lease:) }
    end

    it 'raises Crashed once browserd kills the browser under the session' do
      expect do
        open_session do |session|
          session.goto(FixtureSite.url('/form.html'))
          ApplyMate::Client::Browser::Operation::ReleaseOrphanLeases.call(owner_prefix: owner)

          session.fill(target.css('#email'), 'gone@example.com')
        end
      end.to raise_error(ApplyMate::Client::Browser::Crashed, /browser connection lost/)
      expect(leftover_leases).to eq(0)
    end

    it 'raises DeadlineExceeded from an action once the deadline has passed' do
      deadline = 1.minute.from_now
      described_class.open(deadline:, owner:) do |session|
        session.goto(FixtureSite.url('/form.html'))

        travel_to(deadline + 1.second) do
          expect { session.click(target.css('#email')) }.to raise_error(ApplyMate::Client::Browser::DeadlineExceeded)
          expect(session.settle(:click)).to include(quiet: false)
        end
      end
    end

    it 'releases the lease when the block raises' do
      expect { open_session { raise ArgumentError, 'step failed' } }.to raise_error(ArgumentError, 'step failed')

      expect(leftover_leases).to eq(0)
    end
  end
end
