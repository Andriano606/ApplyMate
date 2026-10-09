# frozen_string_literal: true

require 'rails_helper'

# The REAL snapshot.js + readiness.js + BuildFieldInventory on FixtureSite markup recorded from live Generic forms:
# generic/js_validated.html (a Vuetify, Hurma-like form: JS-only validation, placeholder-only fields, an auto-grow
# sizer textarea, a type=button "Send application", a clipped CV input) and generic/closed.html (a PeopleForce-like
# closed posting with a language switcher outside any form) and generic/hostile.html (PeopleForce hidden twins and an
# Alpine select, Lever's CSS-hidden label text and hCaptcha, Greenhouse's "Attach" upload label, an Ashby autofill
# dropzone, CleverStaff's following consent text and nested buttons, a MacPaw label with an inline link), plus
# generic/send_launcher.html and generic/forms.html for ExecuteAction's no-submit guard against real scopes.
RSpec.describe Apply::Operation::Engine::BuildFieldInventory, :browser do
  let(:ctx) { engine_context(create(:apply)) }

  before { ctx.adopt_match!(Apply::Operation::Engine::Detect::Match.generic) }

  context 'with a JS-validated Vuetify form' do
    it 'leaves out the sizer, keys placeholder-only fields apart and implies the required identity / CV fields' do
      on_fixture_form(ctx, FixtureSite.url('/generic/js_validated.html'), form_root: '#apply') do |_session, fields|
        by_placeholder = fields.index_by(&:placeholder)

        expect(fields.map(&:kind)).to eq(%w[text text text text textarea file])
        expect(fields.map(&:signature).uniq.size).to eq(fields.size)
        expect(fields.map(&:ordinal)).to all(eq(0))
        expect(by_placeholder['Електронна пошта'].description).to eq('Ми надішлемо підтвердження')
        expect(fields.select(&:required).map { |field| field.placeholder || field.kind })
          .to contain_exactly("Ім'я та прізвище", 'Електронна пошта', 'Посилання на портфоліо *', 'file')
      end
    end

    it 'marks the type=button "Send application" submit_like and counts the clipped CV input as rendered' do
      on_fixture_form(ctx, FixtureSite.url('/generic/js_validated.html'), form_root: '#apply') do |session, _fields|
        send = session.snapshot_all.elements.find { |element| element['name'] == 'Send application' }
        readiness = session.probe(:readiness, ApplyMate::Client::Browser::Target.css('#apply'), { 'min' => 1 })

        expect(send).to include('submit_like' => true)
        expect(readiness['fields']).to eq(6) # 5 visible text controls + the clipped file input, never the sizer
      end
    end
  end

  context 'with markup recorded from hostile live forms' do
    let(:url) { FixtureSite.url('/generic/hostile.html') }

    def by_id(snapshot, id)
      snapshot.elements.find { |element| element.dig('attrs', 'id') == id } || raise("no element ##{id}")
    end

    it 'inventories only rendered, answerable controls, labelled by what a person reads' do
      on_fixture_form(ctx, url, form_root: '#apply') do |_session, fields|
        by_label = fields.index_by(&:label)

        expect(fields.map(&:label)).to eq([ 'Номер телефону', 'Супровідний лист', 'Бажана базова компенсація', 'Current location',
                                            'Resume/CV', 'Cover Letter', "Ім'я",
                                            'Я даю дозвіл на обробку своїх персональних даних для цієї та інших вакансій',
                                            'I agree to the Privacy Policy.' ])
        expect(by_label['Номер телефону']).to have_attributes(kind: 'tel', required: true)
        expect(by_label['Супровідний лист']).to have_attributes(kind: 'rich_text')
        expect(by_label['Resume/CV']).to have_attributes(kind: 'file', required: true)
        expect(by_label['Cover Letter']).to have_attributes(kind: 'file', required: false)
        expect(Apply::Operation::Answer::Classify.call(field: by_label['Cover Letter']).model).to eq('cover_letter')
        expect(Apply::Operation::Answer::Classify.call(field: by_label['Current location']).model).to eq('location')
        expect(Apply::Operation::Answer::Classify.call(field: fields[7]).model).to eq('consent_required')
      end
    end

    it 'reports the hidden twins, the captcha field and the readonly select as such' do
      on_fixture_form(ctx, url, form_root: '#apply') do |session, _fields|
        snapshot = session.snapshot_all

        expect(by_id(snapshot, 'career_application_form_phone_numbers')).to include('visible' => false)
        expect(by_id(snapshot, 'g-recaptcha-response')).to include('captcha_artifact' => true, 'visible' => false)
        expect(by_id(snapshot, 'career_application_form[phone_numbers][]')).to include('name' => 'Номер телефону', 'required' => true)
        expect(by_id(snapshot, 'currency')).to include('group' => 'combobox', 'name' => '')
        expect(by_id(snapshot, 'first-name')['strategies']).to include({ 'role' => 'textbox', 'name' => "Ім'я" })
        expect(by_id(snapshot, 'resume-chooser')).to include('required' => false, 'chooser' => false)
        expect(by_id(snapshot, 'hcaptchaSubmitBtn')).to include('name' => '')
        expect(by_id(snapshot, 'close')).to include('name' => 'close')
        expect(snapshot.frames.first['captcha']).to include('hcaptcha_invisible', 'recaptcha_invisible')
      end
    end

    it 'never names the footer locale switcher by the "powered by" credit link before it' do
      on_fixture_form(ctx, url, form_root: '#apply') do |session, _fields|
        expect(by_id(session.snapshot_all, 'career_locale')).to include('name' => '', 'search_like' => true)
      end
    end

    it 'lists one element per clickable thing (nested role=button host / link around a button)' do
      on_fixture_form(ctx, url, form_root: '#apply') do |session, _fields|
        elements = session.snapshot_all.elements

        launchers = elements.select { |element| element['name'] == 'Відгукнутися' && element['scope'].nil? }
        expect(launchers.map { |element| element.dig('attrs', 'id') }).to eq([ 'launcher' ])
        expect(elements.select { |element| element['name'] == 'Apply for this Job' }.map { |element| element['tag'] }).to eq([ 'a' ])
      end
    end
  end

  context 'with send controls the Navigator must never click (hostile.html)' do
    let(:url) { FixtureSite.url('/generic/hostile.html') }

    def element_by_id(snapshot, id)
      snapshot.elements.find { |element| element.dig('attrs', 'id') == id } || raise("no element ##{id}")
    end

    def click(snapshot, element)
      Apply::Operation::Engine::ExecuteAction.call(ctx:, action: { 'type' => 'click', 'ref' => element['ref'] }, snapshot:)
    end

    it 'scopes the dialog button apart from the page launcher and refuses both send controls by name' do
      on_fixture_form(ctx, url, form_root: '#apply') do |session, _fields|
        snapshot = session.snapshot_all
        lone_send = element_by_id(snapshot, 'lone-send')
        modal_send = element_by_id(snapshot, 'modal-send')
        launcher = element_by_id(snapshot, 'launcher')

        expect(lone_send).to include('scope' => nil)
        # type=button with a respond verb: never submit_like, refused by its name inside the dialog with a field
        expect(modal_send).to include('submit_like' => false, 'scope' => 'dialog#respond-modal')
        expect(modal_send['fingerprint']).to eq('button|відгукнутися|f0|dialog#respond-modal')
        expect(launcher['fingerprint']).to eq('button|відгукнутися|f0')
        expect(click(snapshot, lone_send)[:rejected]).to eq('submit_like')
        expect(click(snapshot, modal_send)[:rejected]).to eq('submit_like')
      end
    end
  end

  context 'with launchers the Navigator must be able to click' do
    def element_by_id(snapshot, id)
      snapshot.elements.find { |element| element.dig('attrs', 'id') == id } || raise("no element ##{id}")
    end

    def click(snapshot, element)
      Apply::Operation::Engine::ExecuteAction.call(ctx:, action: { 'type' => 'click', 'ref' => element['ref'] }, snapshot:)
    end

    it 'clicks a send-verb launcher outside any form and sees the modal form open (send_launcher.html)' do
      in_fixture_scope(ctx) do |session|
        session.goto(FixtureSite.url('/generic/send_launcher.html'))
        snapshot = session.snapshot_all
        launcher = element_by_id(snapshot, 'send-launcher')
        result = click(snapshot, launcher)

        expect(launcher).to include('scope' => nil, 'submit_like' => false)
        expect(result[:rejected]).to be_nil
        expect(result[:page_changed]).to be(true)
        expect(element_by_id(result[:snapshot], 'cv-email')).to include('visible' => true, 'scope' => 'dialog#cv-modal')
      end
    end

    it 'scopes id-less forms apart and keeps a "Resend code" out of the send lexicon (forms.html)' do
      in_fixture_scope(ctx) do |session|
        session.goto(FixtureSite.url('/generic/forms.html'))
        snapshot = session.snapshot_all
        apply = element_by_id(snapshot, 'form-apply')

        expect(element_by_id(snapshot, 'newsletter-email')['scope']).to eq('form@1')
        expect(apply['scope']).to eq('form@2')
        expect(element_by_id(snapshot, 'resend')).to include('submit_like' => false, 'scope' => 'form@3')
        expect(element_by_id(snapshot, 'final')).to include('submit_like' => true, 'scope' => 'form@3')
        expect(click(snapshot, apply)[:rejected]).to be_nil
      end
    end
  end

  context 'with a closed posting whose language switcher holds a value' do
    it 'halts closed_posting: the filled switcher is not a form to apply with' do
      in_fixture_scope(ctx) do |session|
        session.goto(FixtureSite.url('/generic/closed.html'))
        snapshot = session.snapshot_all

        expect { Apply::Gate::ClosedPosting.new.call(ctx, snapshot:) }.to raise_error(Apply::Operation::Engine::Halt) { |halt|
          expect(halt).to have_attributes(code: :closed_posting, detail: 'Закрита вакансія')
        }
      end
    end
  end
end
