# frozen_string_literal: true

require 'rails_helper'

# Exercises the real snapshot_fields / page_digest JS in headless Chrome against
# local HTML fixtures — the only coverage for the in-browser IR extraction.
RSpec.describe ApplyMate::Client::Browser do
  def fixture_url(name)
    "file://#{Rails.root.join('spec/fixtures/files/forms', name)}"
  end

  before(:all) { @browser = described_class.new }
  after(:all)  { @browser&.quit }

  describe '#snapshot_fields' do
    context 'with a classic form (labels, fieldset, required, select, radio)' do
      before(:all) do
        @browser.navigate_to(fixture_url('classic.html'))
        @snapshot = @browser.snapshot_fields(scope_selector: '#apply-form')
      end

      let(:fields)   { @snapshot['fields'] }
      let(:by_name)  { fields.index_by { |f| f['name'] } }

      it 'returns the field IR with handles, keeping hidden token inputs' do
        expect(by_name.keys).to include(
          'csrf_token', 'full_name', 'email', 'cover_letter', 'english_level', 'office', 'resume'
        )
        expect(fields).to all(include('handle', 'position', 'accessible_name', 'required', 'autocomplete', 'fieldset'))
      end

      it 'skips invisible visual fields (honeypot) but keeps hidden inputs' do
        expect(by_name).not_to have_key('honeypot_field')
        expect(by_name['csrf_token']).to include('type' => 'hidden', 'value' => 'tok-123')
      end

      it 'resolves accessible names from label[for] and wrapping labels' do
        expect(by_name['full_name']['accessible_name']).to eq("Повне ім'я *")
        expect(by_name['email']['accessible_name']).to eq('Електронна пошта')
        expect(by_name['full_name']['label']).to eq(by_name['full_name']['accessible_name'])
      end

      it 'detects required via attribute, aria-required and * in the label' do
        expect(by_name['full_name']['required']).to be(true)  # required attr + "*"
        expect(by_name['email']['required']).to be(true)      # aria-required
        expect(by_name['cover_letter']['required']).to be(false)
      end

      it 'captures autocomplete and fieldset legend' do
        expect(by_name['email']['autocomplete']).to eq('email')
        expect(by_name['email']['fieldset']).to eq('Контактні дані')
        expect(by_name['cover_letter']['fieldset']).to eq('')
      end

      it 'captures select options and the selected value' do
        english = by_name['english_level']
        expect(english['options']).to include(
          hash_including('label' => 'Advanced', 'value' => 'c1')
        )
        expect(english['value']).to eq('c1')
      end

      it 'returns one entry per radio button for Ruby-side group merging' do
        expect(fields.count { |f| f['name'] == 'office' }).to eq(2)
      end

      it 'stamps every field with data-am-field matching its handle' do
        stamped = @browser.instance_variable_get(:@page).evaluate(
          "Array.from(document.querySelectorAll('[data-am-field]')).map(el => el.getAttribute('data-am-field'))"
        )
        expect(stamped).to include(*fields.map { |f| f['handle'].to_s })
      end

      it 'stamps the submit button and returns its text' do
        expect(@snapshot['submit']).to include('handle' => 'submit', 'text' => 'Надіслати заявку')
      end

      it 'fills a field through its handle so the DOM sees the value' do
        handle = by_name['full_name']['handle']
        @browser.fill_by_handle(handle, 'Jane Doe', 'input')
        value = @browser.instance_variable_get(:@page).evaluate("document.querySelector('[name=\"full_name\"]').value")
        expect(value).to eq('Jane Doe')
      end
    end

    context 'with a Vue-like SPA (random ids, no name attributes, no form tag)' do
      def load_and_snapshot
        @browser.navigate_to(fixture_url('vue_spa.html'))
        @browser.snapshot_fields['fields']
      end

      it 'extracts fields without a form tag, naming them from labels/placeholders' do
        names = load_and_snapshot.map { |f| f['name'] }
        expect(names.length).to eq(3)
        expect(names.join(' ')).to include('input-') # id fallback for labeled fields
        expect(names).to include('Телефон')          # placeholder fallback
      end

      it 'produces identical fingerprints across reloads despite random ids' do
        first  = load_and_snapshot.map { |f| Apply::FieldFingerprint.call(f) }
        second = load_and_snapshot.map { |f| Apply::FieldFingerprint.call(f) }
        expect(first).to eq(second)
        expect(first.uniq.length).to eq(3)
      end
    end

    context 'with custom ARIA widgets' do
      before(:all) do
        @browser.navigate_to(fixture_url('custom_combobox.html'))
        @widget_fields = @browser.snapshot_fields['fields']
      end

      it 'captures role=combobox with its aria-labelledby accessible name' do
        combobox = @widget_fields.find { |f| f['type'] == 'combobox' }
        expect(combobox).to include('tag' => 'div', 'accessible_name' => 'Country of residence',
                                    'required' => true)
      end

      it 'captures contenteditable as a textbox with aria-label and text value' do
        editor = @widget_fields.find { |f| f['name'] == 'pitch-editor' }
        expect(editor).to include('type' => 'textbox', 'accessible_name' => 'Why do you want to join?',
                                  'value' => 'My pitch')
      end
    end
  end

  describe 'ATS widget form without a <form> tag or type="submit"' do
    before(:all) do
      @browser.navigate_to(fixture_url('ats_no_form_tag.html'))
      @ats_snapshot = @browser.snapshot_fields
    end

    it 'extracts the fields even though there is no form element' do
      names = @ats_snapshot['fields'].map { |f| f['accessible_name'] }
      expect(names).to include('Full Name*', 'Email*', 'Phone Number', 'Resume*')
    end

    # ATS forms put the CV input behind a styled dropzone (display:none). It was
    # skipped as invisible, so applications went out with no CV attached.
    it 'keeps a hidden file input — DataTransfer does not need it on screen' do
      resume = @ats_snapshot['fields'].find { |f| f['type'] == 'file' }
      expect(resume['name']).to eq('_systemfield_resume')
      expect(resume['accessible_name']).to eq('Resume*')
    end

    it 'finds the submit button by its wording, not by type=submit' do
      expect(@ats_snapshot['submit']).to include('handle' => 'submit', 'text' => 'Submit Application')
    end

    it 'finds a choice question built from plain buttons, with per-option handles' do
      group = @ats_snapshot['fields'].find { |f| f['type'] == 'button_group' }
      expect(group['accessible_name']).to eq('Are you currently based in Ukraine?')
      expect(group['options'].map { |o| o['label'] }).to eq(%w[Yes No])
      expect(group['options'].map { |o| o['handle'] }).to all(match(/\Aopt-\d+-\d+\z/))
    end

    it 'marks an autocomplete input as a combobox, not a text field' do
      combo = @ats_snapshot['fields'].find { |f| f['name'] == 'src-combo' }
      expect(combo['type']).to eq('combobox')
      expect(combo['accessible_name']).to eq('Where did you hear about us?')
    end

    it 'takes the real label over a placeholder when the two disagree' do
      combobox = @ats_snapshot['fields'].find { |f| f['name'] == 'src-9931' }
      expect(combobox['accessible_name']).to eq('How did you get to know Preply?')
    end

    it 'names a radio group by its question, not by the first option' do
      radios = @ats_snapshot['fields'].select { |f| f['type'] == 'radio' }
      expect(radios.first['group_label']).to eq('Which of the following best describes your gender identity?')
    end

    # Counts every non-hidden control (incl. radios and the yes/no state
    # checkbox) — it only answers "does this page host a form at all?".
    it 'reports a non-zero fillable field count for embed detection' do
      expect(@browser.field_count).to eq(11)
    end
  end

  describe 'page that only embeds its form in an iframe' do
    before(:all) { @browser.navigate_to(fixture_url('embedded_iframe.html')) }

    it 'sees no fields of its own' do
      expect(@browser.field_count).to eq(0)
      expect(@browser.snapshot_fields['fields']).to eq([])
    end

    it 'lists the iframe sources so the embed can be followed' do
      srcs = @browser.iframe_sources
      expect(srcs).to include(a_string_including('jobs.ashbyhq.com'))
      expect(Apply::EmbeddedForm.locate(srcs))
        .to eq('https://jobs.ashbyhq.com/acme/a9419d80-5cf1-4dba-a3d3-e90e5c464495/application')
    end
  end

  # Filling was only ever asserted through doubles: the specs proved which method
  # gets called, never that the browser actually does it. These drive real Chrome.
  describe 'entering values for real' do
    before(:all) do
      @browser.navigate_to(fixture_url('ats_no_form_tag.html'))
      @input_snapshot = @browser.snapshot_fields
    end

    def handle_for(name)
      @input_snapshot['fields'].find { |f| f['name'] == name }['handle']
    end

    def page
      @browser.instance_variable_get(:@page)
    end

    it 'types into a field so the DOM holds the value' do
      expect(@browser.type_by_handle(handle_for('_systemfield_email'), 'dev@example.com')).to be(true)
      expect(page.evaluate("document.querySelector('[name=\"_systemfield_email\"]').value"))
        .to eq('dev@example.com')
    end

    it 'replaces what is already there instead of appending' do
      handle = handle_for('_systemfield_name')
      @browser.type_by_handle(handle, 'First Value')
      @browser.type_by_handle(handle, 'Second Value')
      expect(page.evaluate("document.querySelector('[name=\"_systemfield_name\"]').value"))
        .to eq('Second Value')
    end

    # Writing `value` leaves a checkbox untouched — the bug that let a required
    # consent go out unticked.
    it 'ticks and unticks a checkbox through its checked state' do
      handle = @input_snapshot['fields'].find { |f| f['type'] == 'checkbox' && f['name'].present? }['handle']
      @browser.set_checkbox_by_handle(handle, true)
      expect(@browser.checkbox_checked?(handle)).to be(true)
      @browser.set_checkbox_by_handle(handle, false)
      expect(@browser.checkbox_checked?(handle)).to be(false)
    end

    it 'clicks an element for real, which also ticks a checkbox' do
      handle = @input_snapshot['fields'].find { |f| f['type'] == 'checkbox' && f['name'].present? }['handle']
      @browser.set_checkbox_by_handle(handle, false)
      expect(@browser.click_element_by_handle(handle)).to be(true)
      expect(@browser.checkbox_checked?(handle)).to be(true)
    end

    it 'reports failure for a handle that is not on the page' do
      expect(@browser.type_by_handle('nope-999', 'x')).to be(false)
      expect(@browser.click_element_by_handle('nope-999')).to be(false)
    end
  end

  describe '#select_from_combobox' do
    before(:all) { @browser.navigate_to(fixture_url('combobox.html')) }

    it 'types and chooses the matching option' do
      snapshot = @browser.snapshot_fields
      handle   = snapshot['fields'].find { |f| f['type'] == 'combobox' }['handle']
      expect(@browser.select_from_combobox(handle, 'Linkedin')).to eq('Linkedin')
      page = @browser.instance_variable_get(:@page)
      expect(page.evaluate("document.querySelector('#chosen').textContent")).to eq('Linkedin')
    end

    it 'returns nil when nothing on the list matches' do
      @browser.navigate_to(fixture_url('combobox.html'))
      snapshot = @browser.snapshot_fields
      handle   = snapshot['fields'].find { |f| f['type'] == 'combobox' }['handle']
      expect(@browser.select_from_combobox(handle, 'DOU')).to be_nil
    end
  end

  # The whole point of a persistent profile: a site's cookies (a solved
  # Cloudflare challenge among them) outlive the Chrome process. Ferrum launches
  # Chrome with --keep-alive-for-test, so it never exits cleanly and never writes
  # its own cookie store — these have to be carried across explicitly.
  describe 'browsing with a persistent profile' do
    let(:profile) { "spec_#{SecureRandom.hex(4)}" }

    after { ApplyMate::Client::BrowserProfile.clear(profile) }

    # Set through CDP rather than document.cookie: the fixtures are file:// URLs
    # and Chrome stores no cookies for those, which would test nothing.
    def seed_cookie(browser)
      browser.instance_variable_get(:@browser)
             .cookies.set(name: 'am_probe', value: 'kept', domain: 'example.com', path: '/')
    end

    def cookie_names(browser)
      browser.instance_variable_get(:@browser).cookies.all.keys
    end

    it 'carries cookies into the next Chrome process' do
      first = described_class.new(profile:)
      seed_cookie(first)
      first.quit

      second = described_class.new(profile:)
      expect(cookie_names(second)).to include('am_probe')
      second.quit
    end

    it 'keeps a throwaway session out of that profile' do
      seeded = described_class.new(profile:)
      seed_cookie(seeded)
      seeded.quit

      plain = described_class.new
      expect(cookie_names(plain)).not_to include('am_probe')
      plain.quit
    end

    # A second --user-data-dir does not replace Ferrum's own: Chrome honours the
    # first and the profile silently lands in a temp directory Ferrum deletes.
    it 'passes exactly one profile flag, pointing at the pooled directory' do
      browser = described_class.new(profile:)
      pid     = browser.instance_variable_get(:@browser).process.pid
      argv    = File.read("/proc/#{pid}/cmdline").split("\0").join(' ')

      expect(argv.scan(/--user-data-dir=\S+/).size).to eq(1)
      expect(argv).to include(browser.instance_variable_get(:@profile).path)
      browser.quit
    end
  end

  describe '#observe_state' do
    context 'with a two-step wizard (dynamic steps, validation, success status)' do
      before(:all) { @browser.navigate_to(fixture_url('wizard.html')) }

      it 'observes step 1: visible field, buttons with handles, no alerts' do
        state = @browser.observe_state
        expect(state['fields'].map { |f| f['name'] }).to eq([ 'wiz-name' ])
        expect(state['buttons'].map { |b| b['text'] }).to include('Продовжити')
        expect(state['form_present']).to be(true)
        expect(state['alerts']).to eq([])
        expect(state['captcha']).to be(false)
      end

      it 'clicks a button via its observed handle and sees step 2' do
        state    = @browser.observe_state
        continue = state['buttons'].find { |b| b['text'] == 'Продовжити' }
        @browser.click_by_handle(continue['handle'])

        state2 = @browser.observe_state
        expect(state2['fields'].map { |f| f['name'] }).to eq([ 'wiz-email' ])
        expect(state2['buttons'].map { |b| b['text'] }).to include('Надіслати')
      end

      it 'captures validation errors after a failed submit' do
        submit = @browser.observe_state['buttons'].find { |b| b['text'] == 'Надіслати' }
        @browser.click_by_handle(submit['handle'])

        state = @browser.observe_state
        expect(state['errors']).to include(
          hash_including('name' => 'wiz-email', 'message' => 'Вкажіть email')
        )
        expect(state['alerts']).to include('Вкажіть email')
      end

      it 'sees the success status after a valid submit' do
        state = @browser.observe_state
        email = state['fields'].find { |f| f['name'] == 'wiz-email' }
        @browser.fill_by_handle(email['handle'], 'dev@example.com', 'input')
        submit = state['buttons'].find { |b| b['text'] == 'Надіслати' }
        @browser.click_by_handle(submit['handle'])

        final = @browser.observe_state
        expect(final['alerts'].join).to include('Дякуємо! Заявку отримано.')
        expect(final['fields']).to eq([])
      end
    end
  end

  describe '#page_digest' do
    context 'with a classic form page' do
      before(:all) do
        @browser.navigate_to(fixture_url('classic.html'))
        @digest = @browser.page_digest
      end

      it 'returns title, headings and links' do
        expect(@digest['title']).to eq('Вакансія — Компанія Classic')
        expect(@digest['headings']).to include(
          hash_including('level' => 'h1', 'text' => 'Розробник Ruby')
        )
        expect(@digest['links']).to include(hash_including('text' => 'Про компанію'))
      end

      it 'lists the form with a resolvable selector, its field names and submit text' do
        form = @digest['forms'].first
        expect(form['hidden']).to be(false)
        expect(form['field_names']).to include('full_name', 'email', 'resume')
        expect(form['submit_text']).to eq('Надіслати заявку')
        found = @browser.instance_variable_get(:@page).evaluate("!!document.querySelector(#{form['selector'].to_json})")
        expect(found).to be(true)
      end
    end

    context 'with a formless SPA page' do
      before(:all) do
        @browser.navigate_to(fixture_url('vue_spa.html'))
        @spa_digest = @browser.page_digest
      end

      it 'offers the nearest common ancestor of the fields as fields_container' do
        expect(@spa_digest['forms']).to eq([])
        container = @spa_digest['fields_container']
        expect(container).to be_present
        matches = @browser.instance_variable_get(:@page).evaluate(<<~JS)
          document.querySelector(#{container['selector'].to_json}).querySelectorAll('input').length
        JS
        expect(matches).to eq(3)
      end

      it 'lists visible buttons with their text' do
        expect(@spa_digest['buttons']).to include(
          hash_including('text' => 'Відгукнутися', 'hidden' => false)
        )
      end
    end
  end
end
