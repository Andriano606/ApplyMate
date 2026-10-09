# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Stage::FillFields do
  let(:apply) { create(:apply) }
  let(:ctx) { engine_context(apply) }
  let(:read_values) { {} }
  let(:gemini) { %r{generativelanguage\.googleapis\.com.*generateContent} }
  let(:recovery) { { actions: [], reason: 'the field rejects the value itself', give_up: true } }
  let(:elements) { [ submit_button ] }
  let(:snapshot) { FakeSession::EMPTY_SNAPSHOT.with(elements:) }
  let(:session) do
    FakeSession.new(html: '', final_url: 'https://jobs.ashbyhq.com/preply/x/application', snapshot:, read_values:)
  end
  let(:submit_button) do
    { 'ref' => 'submit', 'tag' => 'button', 'name' => 'Submit Application', 'submit_like' => true, 'visible' => true,
      'regions' => [ '#form' ], 'target' => css('#submit') }
  end
  let(:name) { answer_field(id: 'name', kind: 'text', label: 'Full Name', required: true, target: css('#name')) }
  let(:why) { answer_field(id: 'why', kind: 'textarea', label: 'Why us?', target: css('#why'), max_length: 3) }
  let(:resume) { answer_field(id: 'resume', kind: 'file', label: 'Resume', widget: 'file_input', target: css('#resume')) }
  let(:salary) { answer_field(id: 'salary', kind: 'number', label: 'Salary', target: css('#salary')) }
  let(:token) { answer_field(id: 'token', kind: 'hidden', label: 'Token', widget: nil, target: css('#token')) }
  let(:fields) { [ name, why, resume, salary, token ] }
  let(:answers) do
    { 'name' => answer_entry('Jane Doe', source: 'fact', confidence: 1.0),
      'why' => answer_entry('Because', source: 'fact', confidence: 1.0),
      'resume' => answer_entry(Apply::Operation::Answer::FileRef.cv.as_json, source: 'fact', confidence: 1.0),
      'token' => answer_entry('abc', source: 'fact', confidence: 1.0) }
  end

  def css(selector)
    ApplyMate::Client::Browser::Target.css(selector)
  end

  def fill!
    described_class.call(ctx:)
  end

  before do
    apply.update!(answers:)
    apply.cv.attach(io: StringIO.new('%PDF-1.4 cv'), filename: 'Jane_Doe_CV.pdf', content_type: 'application/pdf')
    ctx.adopt_match!(Apply::Operation::Engine::Detect::Match.new(
      key: 'ashby', confidence: 0.95, captures: { 'slug' => 'preply', 'jid' => '20587adf-cf02-473e-8a80-7b009711a2cf' },
      frame_path: nil, from_alias: false, probable: nil
    ))
    ctx.form_root = css('#form')
    ctx.fields = fields
    ctx.open_scope!(:submit, session, 5.minutes.from_now)
    ctx.scratch.step_record = ApplyStep.create!(apply:, attempt: ctx.attempt, key: 'fill', stage: 'fill', position: 0,
                                                state: :running, started_at: Time.current)
    stub_request(:post, gemini).to_return(gemini_json_response(recovery.to_json))
  end

  it 'has a localized stage name' do
    expect(I18n.t("apply.stage.#{described_class.stage}", locale: :uk)).to be_present
    expect(I18n.t("apply.stage.#{described_class.stage}", locale: :en)).to be_present
  end

  context 'when every value sticks' do
    let(:fields) { [ name, resume, salary, token ] }

    it 'fills the answered fields with read-back, skips the unanswered optional and hidden ones' do
      expect(fill![:step_result]).to eq('filled' => 2, 'unfilled' => [], 'pages' => 1)
      expect(session.calls_of(:fill)).to include([ css('#name'), '' ])
      expect(session.calls_of(:probe)).to include([ :read_value, css('#name') ], [ :read_value, css('#resume') ])
      expect(session.calls.flatten).not_to include(css('#salary'), css('#token'))
    end

    context 'with a display:none honeypot the answers filled' do
      let(:website) { answer_field(id: 'website', kind: 'url', label: 'Website', target: css('#website')) }
      let(:fields) { [ name, resume, website ] }
      let(:answers) { super().merge('website' => answer_entry('https://jane.example', source: 'fact', confidence: 1.0)) }
      let(:session) do
        FakeSession.new(html: '', final_url: 'https://jobs.ashbyhq.com/preply/x/application', snapshot:, read_values:,
                        missing: [ '#website' ])
      end

      it 'never writes the hidden field, does not halt, and traces it hidden_unfilled' do
        expect(fill![:step_result]).to eq('filled' => 2, 'unfilled' => [], 'pages' => 1)
        expect(session.calls_of(:present?)).to include([ css('#website'), { visibility: :required } ])
        expect(session.calls.select { |call| %i[fill type].include?(call.first) }.map(&:second)).not_to include(css('#website'))
        expect(ctx.scratch.trace.find { |entry| entry['event'] == 'hidden_unfilled' }).to include('fields' => [ 'website' ])
      end
    end

    it 'uploads the CV from a temp file that is gone after the stage' do
      fill!

      path = session.calls_of(:upload).sole[1]
      expect(File.basename(path)).to eq('Jane_Doe_CV.pdf')
      expect(File).not_to exist(path)
    end
  end

  context 'when a file field holds a text answer instead of a file reference' do
    let(:fields) { [ name, resume ] }
    let(:answers) do
      { 'name' => answer_entry('Jane Doe', source: 'fact', confidence: 1.0),
        'resume' => answer_entry(Rails.root.join('config/database.yml').to_s, source: 'user', confidence: 1.0) }
    end

    it 'never uploads it as a local path' do
      expect(fill![:step_result]).to eq('filled' => 1, 'unfilled' => [], 'pages' => 1)
      expect(session.calls_of(:upload)).to be_empty
    end
  end

  context 'when an optional value does not stick (maxlength cuts it)' do
    let(:read_values) { { '#why' => 'Bec' } }

    it 'traces it as unfilled, after the fallback write and the AI recovery, and goes on' do
      expect(fill![:step_result]).to eq('filled' => 2, 'unfilled' => [ 'why' ], 'pages' => 1)
      expect(session.calls_of(:type)).to include([ css('#why'), 'Because', { delay_ms: Integer } ])
      expect(ctx.scratch.trace.pluck('event')).to include('widget_fallback', 'recover_turn', 'field_unrecovered', 'unfilled')
      expect(ctx.scratch.step_record.artifacts).not_to be_attached
    end
  end

  context 'when a required value does not stick, even after the recovery' do
    let(:read_values) { { '#name' => { 'displayed' => 'Jane Doe', 'invalid' => true, 'error_text' => 'Too long' } } }

    it 'asks the AI once (give_up), stores a masked unfillable screenshot and halts required_field_unfillable' do
      expect { fill! }.to raise_error(Apply::Operation::Engine::Halt) { |halt|
        expect(halt).to have_attributes(code: :required_field_unfillable, detail: 'name')
      }
      expect(a_request(:post, gemini)).to have_been_made.once
      expect(ctx.scratch.step_record.reload.artifacts.map { |artifact| artifact.filename.to_s }).to eq([ 'unfillable.png' ])
      expect(session.calls).to include([ :screenshot, { full_page: false, mask_fillable: true } ])
    end

    it 'asks a browser-backed integration too (text mode), then halts the same way' do
      apply.ai_integration.update!(provider: 'gemini_scraping')
      client = instance_double(ApplyMate::Ai::Client::GeminiScraping)
      allow(ApplyMate::Ai::Client::GeminiScraping).to receive(:new).and_return(client)
      give_up = { actions: [], reason: 'nothing to click', give_up: true }.to_json
      allow(client).to receive(:complete)
        .and_return(ApplyMate::Ai::Response.new(text: "```json\n#{give_up}\n```", usage: ApplyMate::Ai::Usage::UNKNOWN))

      expect { fill! }.to raise_error(Apply::Operation::Engine::Halt, /required_field_unfillable/)
      expect(client).to have_received(:complete).once
      expect(a_request(:post, gemini)).not_to have_been_made
    end
  end

  context 'when the AI recovery makes a required value stick' do
    let(:fields) { [ name ] }
    let(:read_values) { { '#name' => 'Jan' } }
    let(:recovery) { { actions: [ { type: 'click', ref: 'f0:e0', key: nil, index: nil, max_ms: nil } ], reason: 'x', give_up: false } }
    let(:snapshot) do
      build_snapshot(elements: [ snapshot_element(role: 'button', name: 'Edit', css: '#name-edit', regions: [ '#name' ]) ])
    end

    before do
      session.on(:click) { read_values.delete('#name') }
      session.show(snapshot.with(elements: snapshot.elements + [ submit_button ])) # the form check after filling needs it
    end

    it 'fills the field' do
      expect(fill![:step_result]).to eq('filled' => 1, 'unfilled' => [], 'pages' => 1)
      expect(ctx.scratch.trace.pluck('event')).to include('field_recovered')
    end
  end

  context 'when an autocomplete has no suggestion naming the answer' do
    let(:school) do
      answer_field(id: 'school', kind: 'autocomplete', label: 'School', widget: 'autocomplete', options: 'dynamic',
                   target: css('#school'))
    end
    let(:fields) { [ name, school ] }
    let(:answers) do
      { 'name' => answer_entry('Jane Doe', source: 'fact', confidence: 1.0),
        'school' => answer_entry('Lviv State College', source: 'fact', confidence: 1.0) }
    end
    let(:read_values) { { '#school' => 'Lviv Polytechnic' } }
    let(:session) do
      option = ApplyMate::Client::Browser::Operation::WaitForListbox::Option.new(label: 'Lviv Polytechnic', target: css('#school-0'))
      FakeSession.new(html: '', final_url: 'https://jobs.ashbyhq.com/preply/x/application', snapshot:, read_values:,
                      listbox_options: [ option ])
    end

    it 'stores the first suggestion as an approximate answer and halts review before any claim' do
      expect { fill! }.to raise_error(Apply::Operation::Engine::Halt) { |halt|
        expect(halt).to have_attributes(code: :review, detail: include('approximate'))
      }
      expect(apply.reload.answers['school']).to eq('value' => 'Lviv Polytechnic', 'source' => 'approximate', 'confidence' => 0.5)
      expect(apply.answers['name']).to include('value' => 'Jane Doe')
      expect(apply.submit_claimed_at).to be_nil
      expect(a_request(:post, gemini)).not_to have_been_made
    end
  end

  context 'when a required field has no answer' do
    let(:answers) { { 'why' => answer_entry('Because', source: 'fact', confidence: 1.0) } }

    it 'halts required_field_unfillable before touching the page' do
      expect { fill! }.to raise_error(Apply::Operation::Engine::Halt) { |halt|
        expect(halt).to have_attributes(code: :required_field_unfillable, detail: 'name')
      }
      expect(session.calls_of(:fill)).to be_empty
    end
  end

  context 'when an answer needs the user (low-confidence AI answer)' do
    let(:fields) { [ name ] }
    let(:answers) { { 'name' => answer_entry('Jane Doe', source: 'ai', confidence: 0.2) } }

    it 'fills, then halts for review before any claim' do
      expect { fill! }.to raise_error(Apply::Operation::Engine::Halt) { |halt|
        expect(halt).to have_attributes(code: :review, detail: 'low_confidence')
      }
      expect(session.calls_of(:fill)).not_to be_empty
      expect(apply.reload.submit_claimed_at).to be_nil
    end
  end

  context 'when the form root has neither a submit nor a next button after filling' do
    let(:fields) { [ name ] }
    let(:elements) { [ submit_button.merge('submit_like' => false, 'name' => 'Save draft') ] }

    it 'halts target_not_found before any claim' do
      expect { fill! }.to raise_error(Apply::Operation::Engine::Halt) { |halt|
        expect(halt).to have_attributes(code: :target_not_found, detail: 'no submit or next button in the form')
      }
      expect(apply.reload.submit_claimed_at).to be_nil
    end
  end

  describe 'a wizard (design §7.4)' do
    let(:email) { unique_email('jane') }
    let(:phone) { unique_phone }
    let(:region) { [ '#form' ] }
    let(:next_button) { snapshot_element(role: 'button', name: 'Next', tag: 'button', type: 'button', css: '#next', regions: region) }
    let(:page_one) do
      build_snapshot(frames: [ { outline: [ 'h2 Step 1 of 2' ] } ], elements: [
        snapshot_element(role: 'textbox', name: 'Full name', css: '#full_name', required: true, regions: region),
        snapshot_element(role: 'textbox', name: 'Email', type: 'email', css: '#email', required: true, regions: region),
        snapshot_element(role: 'textbox', name: 'Phone', type: 'tel', css: '#phone', regions: region),
        next_button
      ])
    end
    let(:page_two_outline) { [ 'h2 Step 2 of 2' ] }
    let(:page_two_advance) do
      snapshot_element(role: 'button', name: 'Submit application', tag: 'button', type: 'submit', submit_like: true,
                       css: '#submit', regions: region)
    end
    let(:page_two) do
      build_snapshot(frames: [ { outline: page_two_outline } ], elements: [
        snapshot_element(role: 'textbox', name: 'Cover letter', tag: 'textarea', required: true, regions: region,
                         strategies: [ { 'css' => '#cover' } ]),
        snapshot_element(role: 'checkbox', name: 'I agree to the privacy policy', type: 'checkbox', required: true,
                         regions: region, strategies: [ { 'css' => '#consent' } ]),
        page_two_advance
      ])
    end
    let(:fields) { inventory(page_one) }
    let(:cover_id) { inventory(page_two).first.id }
    let(:consent_id) { inventory(page_two).second.id }
    let(:answers) do
      name_field, email_field, phone_field = fields
      { name_field.id => answer_entry('Jane Doe', source: 'fact', confidence: 1.0),
        email_field.id => answer_entry(email, source: 'fact', confidence: 1.0),
        phone_field.id => answer_entry(phone, source: 'fact', confidence: 1.0) }
    end
    let(:letter) { { 'value' => 'I would love to build this with you.', 'confidence' => 0.9 } }
    let(:session) do
      FakeSession.new(html: '', final_url: 'https://careers.acme.example/jobs/7/apply', snapshot: page_one, read_values:)
    end
    let(:next_target) { page_one.elements.last['target'] }

    # The production ids ("f_<signature>_<ordinal>"); the outer `before` builds `answers` before it sets the form root.
    def inventory(snapshot)
      ctx.form_root ||= css('#form')
      Apply::Operation::Engine::BuildFieldInventory.call(ctx:, snapshot:).model
    end

    def stub_answers(*entries)
      replies = entries.map { |entry| gemini_json_response("```json\n#{{ cover_id => entry }.to_json}\n```") }
      stub_request(:post, gemini).to_return(*replies)
    end

    before do
      ctx.adopt_match!(Apply::Operation::Engine::Detect::Match.generic)
      session.on(:click) { |target| session.show(page_two) if target == next_target }
      # NativeCheck ticks the checkbox through its label; the page then reports the input checked.
      session.on(:set_checked) { read_values['#consent'] = { 'checked' => true } }
    end

    it 'fills page 1, clicks Next once, answers only the new textarea with ONE AI call, fills page 2 and stops at :final' do
      stub_answers(letter)

      expect(fill![:step_result]).to eq('filled' => 5, 'unfilled' => [], 'pages' => 2)
      expect(session.calls_of(:click)).to eq([ [ next_target ] ])
      expect(session.calls_of(:type).map(&:second)).to eq([ 'Jane Doe', email, phone, letter['value'] ]) # submit scope: typed
      expect(session.calls_of(:set_checked).map(&:last)).to eq([ true ])
      expect(a_request(:post, gemini)).to have_been_made.once
      expect(a_request(:post, gemini).with { |req| req.body.include?('Cover letter') && !req.body.include?('privacy') })
        .to have_been_made.once
      expect(ctx.scratch.trace.pluck('event')).to include('wizard_page')
      expect(ctx.scratch.followup_calls).to eq(1)
      expect(ctx.scratch.wizard_page).to eq(2)
      expect(apply.reload.submit_claimed_at).to be_nil
    end

    it 'persists the follow-up fields (with their page) and answers' do
      stub_answers(letter)
      fill!

      expect(apply.reload.field_list.select(&:later_page?).map(&:id)).to eq([ cover_id, consent_id ])
      expect(apply.answers).to include(cover_id => letter.merge('source' => 'ai'), consent_id => include('value' => true, 'source' => 'policy'))
      expect(apply.answers.keys).to include(*fields.map(&:id))
    end

    it 'replays page 2 from the stored answers after an approved review, without asking the AI again' do
      later = inventory(page_two).map { |field| field.with(page: 2, target: nil) }
      ctx.fields = fields + later
      apply.update!(answers: answers.merge(cover_id => answer_entry(letter['value'], confidence: 0.9),
                                           consent_id => answer_entry(true, source: 'user', confidence: 1.0)))
      stub_answers(letter)

      expect(fill![:step_result]).to include('pages' => 2, 'filled' => 5)
      expect(a_request(:post, gemini)).not_to have_been_made
      expect(ctx.scratch.followup_calls).to eq(0)
    end

    context 'when every step is in the DOM and the later one is hidden by CSS' do
      let(:hidden) { [ '#cover' ] }
      let(:session) do
        FakeSession.new(html: '', final_url: 'https://careers.acme.example/jobs/7/apply', snapshot: page_one,
                        read_values:, missing: hidden)
      end
      let(:fields) { inventory(page_one) + [ inventory(page_two).first ] }
      let(:answers) do
        name_field, email_field, phone_field, cover_field = fields
        { name_field.id => answer_entry('Jane Doe', source: 'fact', confidence: 1.0),
          email_field.id => answer_entry(email, source: 'fact', confidence: 1.0),
          phone_field.id => answer_entry(phone, source: 'fact', confidence: 1.0),
          cover_field.id => answer_entry(letter['value'], confidence: 0.9) }
      end

      before { session.on(:click) { hidden.clear } }

      it 'leaves the not-shown step-2 field for page 2 instead of halting on page 1' do
        expect(fill![:step_result]).to eq('filled' => 5, 'unfilled' => [], 'pages' => 2)
        click_at = session.calls.index { |call| call.first == :click }
        cover_at = session.calls.index { |call| call.first == :type && call.second.strategies.first['css'] == '#cover' }
        expect(cover_at).to be > click_at
        expect(a_request(:post, gemini)).not_to have_been_made
      end

      it 'halts required_field_unfillable at :final when the required field never shows' do
        session.on(:click) { hidden << '#cover' }
        cover = fields.last.with(required: true)
        ctx.fields = fields[0..2] + [ cover ]

        expect { fill! }.to raise_error(Apply::Operation::Engine::Halt) { |halt|
          expect(halt).to have_attributes(code: :required_field_unfillable, detail: cover.id)
        }
        expect(session.calls_of(:type).map(&:first)).not_to include(css('#cover'))
      end
    end

    it 'halts target_not_found at the final page when a stored required field of a later page never showed' do
      ctx.fields = fields + [ answer_field(id: 'f_gone_0', label: 'Portfolio', required: true, page: 2, target: nil) ]
      stub_answers(letter)

      expect { fill! }.to raise_error(Apply::Operation::Engine::Halt) { |halt|
        expect(halt).to have_attributes(code: :target_not_found, detail: 'f_gone_0')
      }
    end

    context 'when the AI leaves the new required field blank' do
      it 'halts required_field_unfillable before any claim and without filling page 2' do
        stub_answers({ 'value' => nil, 'confidence' => 0.0 })

        expect { fill! }.to raise_error(Apply::Operation::Engine::Halt) { |halt|
          expect(halt).to have_attributes(code: :required_field_unfillable, detail: cover_id)
        }
        expect(session.calls_of(:fill).map(&:first)).not_to include(page_two.elements.first['target'])
        expect(apply.reload.submit_claimed_at).to be_nil
      end
    end

    context 'when a follow-up answer needs a review (low confidence) and a third page follows' do
      let(:page_two_outline) { [ 'h2 Step 2 of 3' ] }
      let(:page_two_advance) { next_button }

      it 'halts review after filling page 2, before its Next click and before any claim' do
        stub_answers(letter.merge('confidence' => 0.2))

        expect { fill! }.to raise_error(Apply::Operation::Engine::Halt) { |halt|
          expect(halt).to have_attributes(code: :review, detail: 'low_confidence')
        }
        expect(session.calls_of(:click)).to eq([ [ next_target ] ])
        expect(apply.reload.answers[cover_id]).to include('source' => 'ai', 'confidence' => 0.2)
        expect(apply.submit_claimed_at).to be_nil
      end
    end

    context 'when the site refuses page 1 and its Next does not advance' do
      let(:refused) do
        build_snapshot(frames: [ { outline: [ 'h2 Step 1 of 2' ], alerts: [ 'This email is already registered.' ] } ],
                       elements: page_one.elements.map { |element| element.except('ref', 'frame', 'fingerprint', 'target') })
      end

      before { session.on(:click) { |_target| session.show(refused) } }

      it 'halts validation_rejected with the page error after one click, before any claim' do
        expect { fill! }.to raise_error(Apply::Operation::Engine::Halt) { |halt|
          expect(halt).to have_attributes(code: :validation_rejected,
                                          detail: 'next did not advance: This email is already registered.')
        }
        expect(session.calls_of(:click)).to eq([ [ next_target ] ])
        expect(session.calls.drop(session.calls.index { |call| call.first == :click }).count([ :settle, :click ])).to eq(2)
        expect(ctx.scratch.trace).to include(include('event' => 'wizard_stalled', 'page' => 1, 'button' => 'Next'))
        expect(a_request(:post, gemini)).not_to have_been_made
        expect(apply.reload.submit_claimed_at).to be_nil
      end

      it 'names the fields the page marks invalid when it shows no alert' do
        invalid = page_one.elements.map do |element|
          element.except('ref', 'frame', 'fingerprint', 'target').merge('invalid' => element['name'] == 'Email')
        end
        session.on(:click) { |_target| session.show(build_snapshot(frames: [ { outline: [ 'h2 Step 1 of 2' ] } ], elements: invalid)) }

        expect { fill! }.to raise_error(Apply::Operation::Engine::Halt) { |halt|
          expect(halt).to have_attributes(code: :validation_rejected, detail: 'next did not advance: invalid: Email')
        }
      end

      it 'goes on when the page changes during the second settle (a slow transition)' do
        settles = nil
        session.on(:click) { |_target| settles = 0 }
        session.on(:settle) { |profile| session.show(page_two) if settles && profile == :click && (settles += 1) == 2 }
        stub_answers(letter)

        expect(fill![:step_result]).to eq('filled' => 5, 'unfilled' => [], 'pages' => 2)
      end
    end

    context 'with more than MAX_WIZARD_PAGES pages' do
      def step(number)
        build_snapshot(frames: [ { outline: [ "h2 Step #{number} of 7" ] } ], elements: [
          snapshot_element(role: 'textbox', name: 'Full name', css: '#full_name', required: true, regions: region),
          snapshot_element(role: 'textbox', name: 'Email', type: 'email', css: '#email', required: true, regions: region),
          snapshot_element(role: 'textbox', name: 'Phone', type: 'tel', css: '#phone', regions: region),
          next_button
        ])
      end

      let(:page_one) { step(1) }

      before do
        clicks = 0
        session.on(:click) do |_target|
          clicks += 1
          session.show(step(clicks + 1))
        end
      end

      it 'halts wizard_too_long on the sixth page without clicking its Next' do
        expect { fill! }.to raise_error(Apply::Operation::Engine::Halt) { |halt|
          expect(halt).to have_attributes(code: :wizard_too_long, detail: 'more than 6 pages')
        }
        expect(session.calls_of(:click).size).to eq(described_class::MAX_WIZARD_PAGES - 1)
        expect(apply.reload.submit_claimed_at).to be_nil
      end
    end
  end
end
