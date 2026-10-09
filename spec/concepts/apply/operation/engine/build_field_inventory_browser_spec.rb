# frozen_string_literal: true

require 'rails_helper'

# The REAL snapshot.js + BuildFieldInventory on generic/wrapped_fields.html: Hurma's Vuetify inputs 7 levels below the
# item holding their title and "*", its submit in a <footer> inside the <form>, and Ashby's question-description blocks
# beside the label (no aria-describedby).
RSpec.describe Apply::Operation::Engine::BuildFieldInventory, :browser do
  let(:ctx) { engine_context(create(:apply)) }
  let(:url) { FixtureSite.url('/generic/wrapped_fields.html') }

  before { ctx.adopt_match!(Apply::Operation::Engine::Detect::Match.generic) }

  def element(snapshot, id)
    snapshot.elements.find { |el| el.dig('attrs', 'id') == id } || raise("no element ##{id}")
  end

  it 'finds the question and its required mark of an input wrapped 7 levels deep, and reads its semantic' do
    on_fixture_form(ctx, url, form_root: '#response-form') do |_session, fields|
      name = fixture_field(fields, 'First name, last name')
      expect(name).to have_attributes(required: true)
      expect(Apply::Operation::Answer::Classify.call(field: name, platform: nil).model).to eq('full_name')
      expect(fixture_field(fields, 'Email')).to have_attributes(required: true)
    end
  end

  # Hurma: `<span class="country-code">+380</span><input type="tel">` under "Phone number *". The letterless span is an
  # affix, not the label; it is carried as the field's prefix so the phone is typed without its country code.
  it 'labels a tel input by its question, not by the dial-code span before it, and reports the span as its prefix' do
    on_fixture_form(ctx, url, form_root: '#response-form') do |session, fields|
      phone = element(session.snapshot_all, 'phone')
      expect(phone).to include('name' => 'Phone number', 'question' => 'Phone number', 'prefix' => '+380')

      field = fixture_field(fields, 'Phone number')
      expect(field).to have_attributes(kind: 'tel', prefix: '+380', required: true)
      expect(Apply::Operation::Answer::CoerceValue.call(field: field.with(semantic: 'phone'), value: '+380 67 123 45 67').model)
        .to eq('671234567')
    end
  end

  it 'carries the help text beside the label into the description' do
    on_fixture_form(ctx, url, form_root: '#response-form') do |_session, fields|
      expect(fixture_field(fields, 'How did you get to know Preply?').description)
        .to eq('Share with us the one source that led you to apply to Preply')
      expect(fixture_field(fields, 'LinkedIn').description).to start_with('Drop your LinkedIn profile link here.')
      expect(fixture_field(fields, 'Email').description).to be_nil
    end
  end

  it "treats the form's own <footer> as the form: its submit is submit_like, its checkbox a field; the page footer stays chrome" do
    on_fixture_form(ctx, url, form_root: '#response-form') do |session, fields|
      snapshot = session.snapshot_all
      expect(element(snapshot, 'send')).to include('search_like' => false, 'submit_like' => true)
      expect(element(snapshot, 'footer-consent')).to include('search_like' => false)
      expect(fields.map(&:label)).to include('I consent to the processing of my personal data')
      expect(element(snapshot, 'newsletter-email')).to include('search_like' => true)
    end
  end
end
