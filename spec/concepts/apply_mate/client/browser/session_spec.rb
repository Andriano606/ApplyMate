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

  describe '.open lease sizing' do
    let(:driver) { instance_double(ApplyMate::Client::Browser::Driver::Playwright, start: nil, close: nil) }
    let(:deadline) { 20.minutes.from_now }

    def open_with(expires_at)
      lease = instance_double(ApplyMate::Client::Browser::Lease, expires_at:)
      allow(ApplyMate::Client::Browser::Operation::AcquireLease).to receive(:call)
        .and_return(instance_double(ApplyMate::Operation::Result, model: lease))
      allow(ApplyMate::Client::Browser::Driver::Playwright).to receive(:new).and_return(driver)
      described_class.open(deadline:, owner: 'host:1:x') { |session| session }
    end

    it 'asks browserd for a TTL of the deadline plus LEASE_MARGIN_S' do
      freeze_time do
        open_with(deadline + 2.minutes)

        expect(ApplyMate::Client::Browser::Operation::AcquireLease).to have_received(:call)
          .with(owner: 'host:1:x', humanize: false, identity: nil, ttl_s: 20.minutes.to_i + described_class::LEASE_MARGIN_S)
        expect(ApplyMate::Client::Browser::Driver::Playwright).to have_received(:new).with(lease: anything, deadline:)
      end
    end

    it 'cuts its own deadline to the lease expiry minus the margin when browserd granted less' do
      freeze_time do
        expires_at = 10.minutes.from_now
        session = open_with(expires_at)

        expect(ApplyMate::Client::Browser::Driver::Playwright).to have_received(:new)
          .with(lease: anything, deadline: expires_at - described_class::LEASE_MARGIN_S)
        allow(driver).to receive(:deadline).and_return(expires_at - described_class::LEASE_MARGIN_S)
        expect(session.deadline).to eq(expires_at - described_class::LEASE_MARGIN_S)
      end
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
        session.fill(target.css('#email'), unique_email('jane'))
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

        frame_email = unique_email('frame')
        session.fill(target.css('#email', frame_path: by_selector), frame_email)

        by_url = target.css('#email', frame_path: [ { 'url_contains' => '/form.html' } ])
        expect(session.probe(:read_value, by_url)['value']).to eq(frame_email)
        expect(session.html(frame_path: by_selector)).to include('Apply for Ruby Developer')
        expect(session.html).not_to include('Apply for Ruby Developer')
        expect(session.probe(:snapshot, target.css('form#apply', frame_path: by_selector))['elements'])
          .to include(a_hash_including('tag' => 'input', 'name' => 'Email', 'visible' => true,
                                       'attrs' => a_hash_including('id' => 'email')))
      end
    end

    it 'lists the tabs, switches to a new one and rebinds the network tracker to it' do
      open_session do |session|
        session.goto(FixtureSite.url('/new_tab.html'))
        link = target.css('a#open-form')
        expect(session.probe(:opens_tab, link)).to be(true)
        expect(session.probe(:opens_tab, target.css('h1'))).to be(false)
        session.network_watch(%r{/newsletter\z})

        session.click(link)
        expect(session.wait_until(timeout: 5) { session.pages.size == 2 }).to be(true)
        expect(session.pages.last).to eq('url' => FixtureSite.url('/form.html'))
        expect(session.current_url).to eq(FixtureSite.url('/new_tab.html')) # a new tab never takes the session itself

        session.switch_to(1)
        expect(session.current_url).to eq(FixtureSite.url('/form.html'))
        expect(session.frames).to eq([ { 'url' => FixtureSite.url('/form.html'), 'name' => '' } ])

        mark = session.network_mark
        session.click(target.css('#newsletter button'))
        session.settle(:click)
        expect(session.network_since(mark, bodies: true)) # the watch registered on the first tab carried over
          .to contain_exactly(a_hash_including(method: 'POST', url: FixtureSite.url('/newsletter'), status: 404, body: 'not found'))

        session.switch_to(0)
        expect(session.html).to include('opens in a new tab')
        expect { session.switch_to(5) }.to raise_error(IndexError)
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

          session.fill(target.css('#email'), unique_email('gone'))
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

    describe 'phase 3a primitives (Ashby and widget fixtures)' do
      let(:schema_keys) do
        JSON.parse(FixtureSite::ASHBY_POSTING_JSON.read)
            .dig('data', 'jobPosting', 'applicationForm', 'sections', 0, 'fieldEntries').map { |entry| entry.dig('field', 'path') }
      end
      let(:radio_path) { 'ab315a8b-7c2d-4e9f-8a1b-5c6d7e8f9a06' }

      def element(snapshot, name, frame: nil)
        snapshot.elements.find { |el| el['name'] == name && (frame.nil? || el['frame'] == frame) } ||
          raise("no element named #{name.inspect}")
      end

      it 'snapshots the page and the cross-origin embed iframe, shadow roots included, with targets Locate resolves' do
        open_session do |session|
          session.goto(FixtureSite.url('/ashby/company.html'))
          markers = [ 'iframe#ashby_embed_iframe', '.ashby-application-form-field-entry' ]
          # The embed iframe is injected after 300 ms and the banner's shadow root attaches after 1 s: wait for both
          # (the banner button and the embed's tab) instead of sleeping.
          snapshot = session.wait_until(timeout: 10) do
            current = session.snapshot_all(markers:)
            current if current.elements.any? { |el| el['name'] == 'Accept necessary only' } &&
                       current.elements.any? { |el| el['frame'] == 'f1' && el['role'] == 'tab' }
          end
          expect(snapshot).to be_a(ApplyMate::Client::Browser::Snapshot)

          embed = snapshot.frames.find { |frame| frame['ref'] == 'f1' }
          expect(embed).to include('parent' => 'f0', 'frame_path' => [ { 'selector' => 'iframe#ashby_embed_iframe' } ])
          expect(embed['url']).to eq(FixtureSite.alt_url('/ashby/posting.html?embed=js'))
          expect(snapshot.evidence).to include(
            iframe_srcs: [ FixtureSite.alt_url('/ashby/posting.html?embed=js') ],
            script_srcs: include(FixtureSite.alt_url('/ashby/embed.js?version=2')),
            dom_markers: { 'iframe#ashby_embed_iframe' => 1, '.ashby-application-form-field-entry' => 0 }
          )
          expect(snapshot.digest).to match(/\A\h{40}\z/)

          accept = element(snapshot, 'Accept necessary only', frame: 'f0') # inside the banner's open shadow root
          expect(accept).to include('ref' => start_with('f0:e'), 'role' => 'button', 'visible' => true)
          session.click(accept['target'])
          expect(session.present?(accept['target'], visibility: :attached)).to be(false)

          tab = element(snapshot, 'Application', frame: 'f1')
          expect(tab).to include('role' => 'tab', 'fingerprint' => 'tab|application|f1', 'search_like' => false)
          session.click(tab['target'])
          form_root = target.css('#form[role=tabpanel]', frame_path: tab['target'].frame_path)
          expect(session.ready?(form_root, timeout: 15, keys: schema_keys, attr: 'data-field-path')).to be(true)

          fields = session.snapshot_all.elements.select { |el| el['frame'] == 'f1' }
          resume = fields.find { |el| el.dig('attrs', 'data-field-path') == '_systemfield_resume' && el['type'] == 'file' }
          expect(resume).to include('name' => 'Resume', 'required' => true, 'self_visible' => false, 'visible' => true)
          expect(session.present?(resume['target'], visibility: :required)).to be(true) # judged on the dropzone root

          radios = fields.select { |el| el['group'] == 'radio_group' }
          expect(radios.map { |el| el.values_at('self_visible', 'visible') }.uniq).to eq([ [ false, true ] ])
          expect(radios.first['question']).to eq('How many years have you managed support agents?')
          expect(radios.first['options'].pluck('label')).to eq([ 'Less than 2 years', '3-5 years', 'More than 5 years' ])
          expect(radios.flat_map { |el| el['strategies'] }.filter_map { |s| s['attr'] }).to be_empty # instance-prefixed
          expect(session.present?(radios.second['target'], visibility: :required)).to be(true)

          expect(fields.find { |el| el['group'] == 'combobox' })
            .to include('name' => 'How did you get to know Preply?', 'required' => true)
          expect(fields.select { |el| el['group'] == 'option_group' }.pluck('name')).to eq(%w[Yes No])
          expect(fields.select { |el| el['submit_like'] }.pluck('name')).to eq([ 'Submit Application' ])
          expect(fields.find { |el| el['name'] == 'Full Name' }['filled']).to be(false)
        end
      end

      it 'types, opens the keyboard-only combobox, masks screenshots and captures the watched submit response' do
        open_session do |session|
          session.goto(FixtureSite.alt_url('/ashby/application.html?embed=js'))
          prefix = Apply::Platform::Ashby::INSTANCE_PREFIX_SOURCE
          expect(session.ready?(target.css('#form'), timeout: 10, keys: [ radio_path, '_systemfield_resume' ],
                                                     attr: 'name', ratio: 1.0, key_prefix: prefix)).to be(true)
          # The probe knows no platform: without the platform's prefix the per-render radio name never matches.
          expect(session.ready?(target.css('#form'), timeout: 0.5, keys: [ radio_path, '_systemfield_resume' ],
                                                     attr: 'name', ratio: 1.0)).to be(false)
          expect(session.ready?(target.css('#form'), timeout: 0.5, keys: %w[a b c d e], attr: 'name')).to be(false)

          name = target.css('#_systemfield_name')
          session.type(name, 'Test Applicant', delay_ms: 5)
          expect(session.probe(:read_value, name)).to include('value' => 'Test Applicant', 'displayed' => 'Test Applicant')

          combobox = target.css('input[role=combobox]')
          mark = session.dom_mark(combobox)
          session.click(combobox) # a click does not open it (live probe)
          expect(session.wait_for_listbox(since: mark, timeout: 1)).to eq([])

          session.press(combobox, 'ArrowDown')
          options = session.wait_for_listbox(since: mark, timeout: 5)
          expect(options.size).to eq(15)
          expect(options.first).to have_attributes(label: 'Word of mouth')
          session.click(options.find { |option| option.label == 'LinkedIn' }.target)
          expect(session.probe(:read_value, combobox)).to include('displayed' => 'LinkedIn', 'invalid' => false)

          expect(session.screenshot(mask_fillable: true)).to start_with("\x89PNG".b)

          session.network_watch(%r{/ashby/api/non-user-graphql\?op=ApiSubmit})
          network_mark = session.network_mark
          session.click(target.css('button.ashby-application-form-submit-button'))
          session.settle(:submit)
          # The fixture submits ~1 s after the click (the reCAPTCHA token), past the settle, with a dozen unrelated
          # POSTs (ApiSetFormValue, a RUM beacon) at the same moment. requestfinished may reach Ruby after the page
          # rendered its answer, so wait for both.
          submitted = session.wait_until(timeout: 10) do
            session.html(frame_path: []).include?('ashby-application-form-success-container') &&
              session.network_since(network_mark).any? { |record| record[:url].include?('op=ApiSubmit') }
          end
          expect(submitted).to be_truthy

          records = session.network_since(network_mark, bodies: true)
          submit, others = records.partition { |record| record[:url].include?('op=ApiSubmitSingleApplicationFormAction') }
          expect(submit.sole).to include(method: 'POST', status: 200, body: FixtureSite::ASHBY_SUBMIT_ANSWERS[:success], body_error: nil)
          expect(others).to be_present.and all(include(body: nil, body_error: nil)) # unwatched: never read
          expect(session.network_since(network_mark).pluck(:body)).to all(be_nil)
          expect(FixtureSite.submissions.sole).to include(op: 'ApiSubmitSingleApplicationFormAction')
          expect(JSON.parse(FixtureSite.submissions.sole[:body]).dig('variables', 'values'))
            .to include('_systemfield_name' => 'Test Applicant', '9f2c7a14-5e3b-4d6a-8c1f-0a2b3c4d5e04' => 'LinkedIn')
        end
      end

      it 'finds portal and readonly listboxes, reads pressed buttons, scrolls, waits, and raises Obstructed' do
        open_session do |session|
          session.goto(FixtureSite.url('/widgets.html'))

          country = target.css('#country-input')
          mark = session.dom_mark(country)
          session.click(country)
          options = session.wait_for_listbox(since: mark, timeout: 5) # the menu is appended to <body>
          expect(options.map(&:label)).to eq(%w[Ukraine Poland Germany Portugal])
          session.click(options.second.target)
          expect(session.probe(:read_value, country)['displayed']).to eq('Poland')

          city = target.css('#city-input')
          mark = session.dom_mark(city)
          session.click(city)
          expect(session.wait_for_listbox(since: mark, timeout: 5).map(&:label)).to eq(%w[Kyiv Lviv Odesa])

          snapshot = session.snapshot_all
          expect(element(snapshot, 'City')).to include('group' => 'combobox', 'readonly' => true)
          expect(element(snapshot, 'City')['target'].readonly?).to be(true)

          yes = element(snapshot, 'Yes')
          expect(yes).to include('group' => 'option_group', 'question' => 'Do you have a work permit?')
          session.click(yes['target'])
          expect(session.probe(:read_value, yes['target'])['pressed']).to eq('true')

          far = target.css('#far-input')
          session.scroll_into_view(far)
          expect(element(session.snapshot_all, 'Far input')['in_viewport']).to be(true)

          expect(session.wait_until(timeout: 0.3) { false }).to be(false)
          overlay = target.css('#cookie-overlay')
          expect(session.wait_until(timeout: 6) { session.present?(overlay, visibility: :required) }).to be(true)
          expect { session.trial_click(target.css('#continue')) } # the same checks, no click (Stage::Submit)
            .to raise_error(ApplyMate::Client::Browser::Obstructed, /intercepts pointer events/)
          expect { session.click(target.css('#continue')) }
            .to raise_error(ApplyMate::Client::Browser::Obstructed, /intercepts pointer events/)
        end
      end

      it 'counts schema keys of hidden elements in keys mode' do
        open_session do |session|
          session.goto(FixtureSite.url('/form.html')) # #remote is display: none
          apply_form = target.css('form#apply')

          expect(session.ready?(apply_form, timeout: 1, keys: %w[remote cv], attr: 'name', ratio: 1.0)).to be(true)
          expect(session.ready?(apply_form, timeout: 0.3, keys: %w[remote missing], attr: 'name', ratio: 1.0)).to be(false)
        end
      end
    end

    it 'releases the lease when the block raises' do
      expect { open_session { raise ArgumentError, 'step failed' } }.to raise_error(ArgumentError, 'step failed')

      expect(leftover_leases).to eq(0)
    end
  end
end
