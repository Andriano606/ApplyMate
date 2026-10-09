# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Engine::BuildFieldInventory do
  let(:apply) { create(:apply) }
  let(:ctx) { engine_context(apply) }
  let(:form_root) { ApplyMate::Client::Browser::Target.css('#form[role="tabpanel"]') }
  let(:read_values) { {} }
  let(:session) { FakeSession.new(html: '', final_url: 'https://jobs.ashbyhq.com/preply/x/application', snapshot:, read_values:) }
  let(:jid) { '20587adf-cf02-473e-8a80-7b009711a2cf' }
  let(:ashby_match) do
    Apply::Operation::Engine::Detect::Match.new(key: 'ashby', confidence: 0.95, captures: { 'slug' => 'preply', 'jid' => jid },
                                                frame_path: nil, from_alias: false, probable: nil)
  end

  subject(:fields) { described_class.call(ctx:, snapshot:).model }

  before do
    ctx.form_root = form_root
    ctx.open_scope!(:survey, session, 5.minutes.from_now)
  end

  def field(id)
    fields.find { |candidate| candidate.id == "ashby:#{id}" } || raise("no field #{id} in #{fields.map(&:id)}")
  end

  # The production Snapshot of the fixture's Ashby application page (spec/support/fixture_site/pages/ashby/
  # application.html): a Driver#evaluate_all_frames result recorded from Camoufox, built by SnapshotAll.
  context 'with the Ashby application page' do
    let(:snapshot) do
      raw = JSON.parse(file_fixture('apply_engine/ashby/application_frames.json').read).map { |frame| frame.transform_keys(&:to_sym) }
      driver = instance_double(ApplyMate::Client::Browser::Driver::Playwright, evaluate_all_frames: raw)
      ApplyMate::Client::Browser::Operation::SnapshotAll.call(driver:, regions: Apply::Operation::Engine::FormElements.regions(ctx)).model
    end

    before { ctx.adopt_match!(ashby_match) }

    context 'with the posting schema' do
      before do
        allow(ApplyMate::Net::Operation::ResolvePublicAddress).to receive(:call) { |url:| FixtureSite.resolution(url) }
        allow(ctx.http).to receive(:post)
          .and_return(ApplyMate::Client::Response.new(file_fixture('apply_engine/ashby/api_job_posting.json').read, {}, 200, nil))
        ctx.schema = ctx.platform.fetch_schema
      end

      it 'has one field per schema entry, in DOM order, and none from the autofill pane' do
        expect(fields.size).to eq(15)
        expect(fields.map(&:id)).to eq(ctx.schema.map(&:id))
        expect(fields.count(&:file?)).to eq(1)
        expect(fields.map { |candidate| candidate.target.strategies.first }).not_to include(a_hash_including('css' => /autofill/))
        expect(fields).to all(have_attributes(source: 'schema_api', ordinal: 0))
      end

      it 'takes kind, label, required and options from the schema, widget and target from the DOM' do
        expect(field('9f2c7a14-5e3b-4d6a-8c1f-0a2b3c4d5e04')).to have_attributes(
          kind: 'combobox', widget: 'aria_combobox', required: true, label: 'How did you get to know Preply?',
          options: have_attributes(size: 15), target: have_attributes(strategies: include({ 'role' => 'combobox', 'name' => 'How did you get to know Preply?' }))
        )
        expect(field('_systemfield_resume')).to have_attributes(
          kind: 'file', widget: 'file_input', target: have_attributes(root: include({ 'attr' => { 'data-field-path' => '_systemfield_resume' } }))
        )
        expect(field('6257e5b0-1d2a-4c55-9a51-3f0f2a6c1e01')).to have_attributes(kind: 'tel', widget: 'text')
        expect(field('8f841092-5f6a-4b7c-9d8e-0f1a2b3c4d09')).to have_attributes(kind: 'textarea', widget: 'text', required: false)
      end

      it 'maps Boolean and small ValueSelect fields to the group kind the DOM shows' do
        expect(ctx.schema.find { |schema| schema.id.end_with?('c1d2e3f4-6a7b-4c8d-9e0f-1a2b3c4d5e10') }.kind).to eq('radio_group')
        expect(field('c1d2e3f4-6a7b-4c8d-9e0f-1a2b3c4d5e10')).to have_attributes(
          kind: 'option_group', widget: 'option_group', options: [ { 'label' => 'Yes', 'value' => 'true' }, { 'label' => 'No', 'value' => 'false' } ]
        )
        expect(field('ab315a8b-7c2d-4e9f-8a1b-5c6d7e8f9a06')).to have_attributes(
          kind: 'radio_group', widget: 'option_group', options: have_attributes(size: 3),
          target: have_attributes(root: include({ 'attr' => { 'data-field-path' => 'ab315a8b-7c2d-4e9f-8a1b-5c6d7e8f9a06' } }))
        )
        expect(field('c408722a-7b8c-4d9e-8f0a-2b3c4d5e6f11')).to have_attributes(kind: 'checkbox_group', widget: 'option_group')
      end

      it 'keeps the signature of the label, kind and option labels (the identity ReconcileFields matches on)' do
        combobox = field('9f2c7a14-5e3b-4d6a-8c1f-0a2b3c4d5e04')

        expect(combobox.signature).to eq(Apply::Field.signature_for(label: combobox.label, kind: 'combobox',
                                                                    option_labels: combobox.options.pluck('label')))
      end
    end

    it 'reads kinds, labels and options from the DOM without a schema' do
      expect(fields.size).to eq(14)
      expect(fields).to all(have_attributes(source: 'snapshot'))
      expect(field('9f2c7a14-5e3b-4d6a-8c1f-0a2b3c4d5e04')).to have_attributes(kind: 'combobox', options: 'dynamic')
      # The bare "Acknowledge/Confirm" checkbox keeps its name (NativeCheck clicks that label); its question becomes the
      # description, which the lexicon reads as consent.
      gdpr = field('c408722a-7b8c-4d9e-8f0a-2b3c4d5e6f11')
      expect(gdpr).to have_attributes(kind: 'checkbox', widget: 'native_check', label: 'Acknowledge/Confirm',
                                      description: 'Privacy notice', required: true)
      expect(Apply::Operation::Answer::Classify.call(field: gdpr).model).to eq('consent_required')
    end

    it 'drops the optional field with an empty label and a generic placeholder (nothing to answer)' do
      expect(fields.map(&:id)).not_to include(a_string_including('3086edf6-0b7d-4a3c-8e2f-9d4c1b5a6e03'))
    end
  end

  context 'with hand-made snapshot elements (generic platform)' do
    let(:form_root) { ApplyMate::Client::Browser::Target.css('form') }
    let(:elements) { [] }
    let(:snapshot) { FakeSession::EMPTY_SNAPSHOT.with(elements:) }

    def element(css, name, type: 'text', tag: 'input', regions: [ 'form' ], frame_path: [], **extra)
      { 'ref' => "f0:e#{css}", 'tag' => tag, 'type' => type, 'role' => 'textbox', 'name' => name, 'visible' => true,
        'regions' => regions, 'attrs' => {},
        'target' => ApplyMate::Client::Browser::Target.css(css, frame_path:) }.merge(extra.stringify_keys)
    end

    context 'with two controls of the same label and kind' do
      let(:elements) { [ element('#phone_1', 'Phone'), element('#phone_2', 'Phone') ] }

      it 'numbers them by DOM order (ordinal) and builds the ids from signature and ordinal' do
        signature = Apply::Field.signature_for(label: 'Phone', kind: 'text', option_labels: nil)

        expect(fields.map(&:ordinal)).to eq([ 0, 1 ])
        expect(fields.map(&:id)).to eq([ "f_#{signature}_0", "f_#{signature}_1" ])
        expect(fields.map(&:signature).uniq).to eq([ signature ])
      end
    end

    context 'with placeholder-only controls (no label, no question)' do
      let(:elements) do
        [
          element('#name', "Ім'я та прізвище *", required: true, attrs: { 'placeholder' => "Ім'я та прізвище *" }),
          element('#about', '', tag: 'textarea', type: nil, attrs: { 'placeholder' => 'Type here...' }),
          element('#birth', '', required: true, attrs: { 'placeholder' => 'dd.mm.yyyy' })
        ]
      end

      it 'labels one by its placeholder without the required mark, never by a generic placeholder or a date mask' do
        expect(fields.map { |field| [ field.label, field.placeholder, field.required ] }).to eq([
          [ "Ім'я та прізвище", "Ім'я та прізвище *", true ], [ nil, 'dd.mm.yyyy', true ]
        ])
        expect(fields.first.signature).to eq(Apply::Field.signature_for(label: "Ім'я та прізвище", kind: 'text', option_labels: nil))
      end
    end

    context 'with controls nobody answers' do
      let(:elements) do
        [
          element('#twin', 'Phone', type: 'tel', visible: false, self_visible: false, required: true),
          element('#g-recaptcha-response', '', tag: 'textarea', type: nil, visible: false, captcha_artifact: true),
          element('#currency', 'USD - United States Dollar', readonly: true, self_visible: true),
          element('#autofill', '', type: 'file', role: nil, question: 'Autofill from resume'),
          element('#phone', 'Phone', type: 'tel')
        ]
      end

      it 'leaves out non-rendered twins, captcha fields, readonly inputs and resume-parse helpers' do
        expect(fields.map { |field| field.target.strategies.first['css'] }).to eq([ '#phone' ])
      end

      it 'agrees with AssessFormLikeness and the Navigator on what a control is' do
        expect(elements.map { |el| described_class.control?(el) }).to eq([ false, false, false, true, true ])
      end
    end

    context 'with several upload fields' do
      let(:elements) do
        [
          element('#resume', 'Attach', type: 'file', role: nil, question: 'Resume/CV'),
          element('#cover_letter', 'Attach', type: 'file', role: nil, question: 'Cover Letter'),
          element('#files', 'Need to share files with us? Attach PDF, PNG or JPG formats only.', type: 'file', role: nil)
        ]
      end

      it 'labels a generic "Attach" by its question and implies required only for the CV slot' do
        expect(fields.map { |field| [ field.label, field.required ] }).to eq([
          [ 'Resume/CV', true ], [ 'Cover Letter', false ],
          [ 'Need to share files with us? Attach PDF, PNG or JPG formats only.', false ]
        ])
      end
    end

    # Hurma / Vuetify validate in JS only: no required attribute, the requirement is a mark or a word in the text.
    context 'with JS-only required-ness (no required attribute anywhere)' do
      let(:elements) do
        [
          element('#first', 'Імʼя'), element('#role', 'Посада', attrs: { 'placeholder' => 'Ваша посада ✱' }),
          element('#city', 'Місто', attrs: { 'placeholder' => "Обов'язкове поле" }),
          element('#mail', 'Email'), element('#tel', 'Phone (optional)', type: 'tel'),
          element('#who', 'Full name'), element('#note', "Коментар (необов'язково)"),
          element('#cv', 'Attach', type: 'file', role: nil, question: 'Резюме'),
          element('#portfolio', 'Portfolio', type: 'file', role: nil),
          element('#extra', 'Додаткові файли', type: 'file', role: nil)
        ]
      end

      it 'reads marks and required words, defaults name / email / phone / CV to required, and lets "optional" win' do
        expect(fields.to_h { |field| [ field.label, field.required ] }).to eq(
          'Імʼя' => true, 'Посада' => true, 'Місто' => true, 'Email' => true, 'Phone (optional)' => false, 'Full name' => true,
          "Коментар (необов'язково)" => false, 'Резюме' => true, 'Portfolio' => false, 'Додаткові файли' => false
        )
      end
    end

    context 'with controls that are not fields of this form' do
      let(:elements) do
        [
          element('#q', 'Search jobs', type: 'search', search_like: true),
          element('#locked', 'Locked', disabled: true),
          element('#outside', 'Newsletter email', regions: []),
          element('#framed', 'Framed', frame_path: [ { 'selector' => 'iframe#other' } ]),
          element('#apply', 'Submit', tag: 'button', type: 'submit', role: 'button', submit_like: true),
          element('#name', 'Name')
        ]
      end

      it 'keeps only fillable controls inside the form root of its frame' do
        expect(fields.map(&:label)).to eq([ 'Name' ])
      end
    end

    context 'with a prefilled control' do
      let(:elements) { [ element('#city', 'City', filled: true) ] }
      let(:read_values) { { '#city' => 'Kyiv' } }

      it 'reads its current value as default_value' do
        expect(fields.sole.default_value).to eq('Kyiv')
      end
    end

    context 'with an autocomplete attribute' do
      let(:elements) { [ element('#who', 'Reach me', attrs: { 'autocomplete' => 'given-name' }) ] }

      it 'keeps it on the field, where Answer::Classify reads it' do
        field = fields.sole

        expect(field.autocomplete).to eq('given-name')
        expect(Apply::Operation::Answer::Classify.call(field:).model).to eq('first_name')
      end
    end

    context 'with the widget-specific controls' do
      let(:elements) do
        [
          element('#zone', 'Upload resume', tag: 'button', type: 'button', role: 'button', chooser: true),
          element('#plain', 'Upload', tag: 'button', type: 'button', role: 'button', chooser: false),
          element('#school', 'School', role: 'combobox', group: 'combobox', attrs: { 'aria-autocomplete' => 'list' }),
          element('#country', 'Country', role: 'combobox', group: 'combobox',
                                         attrs: { 'aria-autocomplete' => 'list', 'aria-haspopup' => 'true' }),
          element('#cover', 'Cover letter', tag: 'div', type: nil),
          element('#birth', 'Birth date', attrs: { 'placeholder' => 'dd.mm.yyyy' }),
          element('#start', 'Start date', type: 'date'),
          element('#years', 'Years of experience', type: 'range', role: 'slider')
        ]
      end

      it 'maps each to its kind and driver: a chooser button is a dropzone file, a plain button no field' do
        expect(fields.map { |field| [ field.label, field.kind, field.widget ] }).to eq(
          [
            [ 'Upload resume', 'file', 'dropzone' ], [ 'School', 'autocomplete', 'autocomplete' ],
            [ 'Country', 'combobox', 'aria_combobox' ], [ 'Cover letter', 'rich_text', 'content_editable' ],
            [ 'Birth date', 'date', 'date_input' ], [ 'Start date', 'date', 'date_input' ],
            [ 'Years of experience', 'range', 'range' ]
          ]
        )
      end
    end

    context 'with custom selects and an ARIA-less typeahead' do
      let(:elements) do
        [
          element('#location', 'Current location', typeahead: true),
          *(1..7).map { |n| element("#select#{n}", "Select #{n}", role: 'combobox', group: 'combobox', readonly: true) }
        ]
      end
      let(:session) do
        options = %w[AED USD AED].map do |label|
          ApplyMate::Client::Browser::Operation::WaitForListbox::Option.new(label:, target: ApplyMate::Client::Browser::Target.css('.item'))
        end
        FakeSession.new(html: '', final_url: 'https://jobs.example/apply', snapshot:, read_values:, listbox_options: options)
      end

      it 'writes the typeahead with Typeahead and opens the first MAX_PROBED_COMBOBOXES comboboxes for their options' do
        expect(fields.first).to have_attributes(kind: 'autocomplete', widget: 'typeahead', options: 'dynamic')
        comboboxes = fields.drop(1)
        expect(comboboxes.map(&:widget)).to all(eq('aria_combobox'))
        expect(comboboxes.first(described_class::MAX_PROBED_COMBOBOXES).map(&:options))
          .to all(eq([ { 'label' => 'AED', 'value' => 'AED' }, { 'label' => 'USD', 'value' => 'USD' } ]))
        expect(comboboxes.last.options).to eq('dynamic')
        expect(comboboxes.map(&:signature)).to eq(
          (1..7).map { |n| Apply::Field.signature_for(label: "Select #{n}", kind: 'combobox', option_labels: nil) }
        )
      end
    end

    context 'when the platform key gives two controls the same id' do
      let(:elements) do
        [ element('#a', 'First', attrs: { 'data-field-path' => 'same' }), element('#b', 'Second', attrs: { 'data-field-path' => 'same' }) ]
      end

      it 'halts unexpected_error (field id collision)' do
        ctx.adopt_match!(ashby_match)

        expect { fields }.to raise_error(Apply::Operation::Engine::Halt) { |halt|
          expect(halt).to have_attributes(code: :unexpected_error, detail: 'field id collision')
        }
      end
    end

    it 'halts not_a_form without a form root' do
      ctx.form_root = nil

      expect { fields }.to raise_error(Apply::Operation::Engine::Halt, /not_a_form/)
    end
  end
end
