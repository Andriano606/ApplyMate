# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Stage::FillFields do
  let(:apply) { create(:apply) }
  let(:ctx) { engine_context(apply) }
  let(:read_values) { {} }
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
  end

  it 'has a localized stage name' do
    expect(I18n.t("apply.stage.#{described_class.stage}", locale: :uk)).to be_present
    expect(I18n.t("apply.stage.#{described_class.stage}", locale: :en)).to be_present
  end

  context 'when every value sticks' do
    let(:fields) { [ name, resume, salary, token ] }

    it 'fills the answered fields with read-back, skips the unanswered optional and hidden ones' do
      expect(fill![:step_result]).to eq('filled' => 2, 'unfilled' => [])
      expect(session.calls_of(:fill)).to include([ css('#name'), '' ])
      expect(session.calls_of(:probe)).to include([ :read_value, css('#name') ], [ :read_value, css('#resume') ])
      expect(session.calls.flatten).not_to include(css('#salary'), css('#token'))
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
      expect(fill![:step_result]).to eq('filled' => 1, 'unfilled' => [])
      expect(session.calls_of(:upload)).to be_empty
    end
  end

  context 'when an optional value does not stick (maxlength cuts it)' do
    let(:read_values) { { '#why' => 'Bec' } }

    it 'traces it as unfilled, after the fallback write, and goes on' do
      expect(fill![:step_result]).to eq('filled' => 2, 'unfilled' => [ 'why' ])
      expect(session.calls_of(:type)).to include([ css('#why'), 'Because', { delay_ms: Integer } ])
      expect(ctx.scratch.trace.pluck('event')).to include('widget_fallback', 'unfilled')
    end
  end

  context 'when a required value does not stick' do
    let(:read_values) { { '#name' => { 'displayed' => 'Jane Doe', 'invalid' => true, 'error_text' => 'Too long' } } }

    it 'halts required_field_unfillable with the field id' do
      expect { fill! }.to raise_error(Apply::Operation::Engine::Halt) { |halt|
        expect(halt).to have_attributes(code: :required_field_unfillable, detail: 'name')
      }
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

  context 'when the form root has no submit button after filling (a multi-page form)' do
    let(:fields) { [ name ] }
    let(:elements) { [ submit_button.merge('submit_like' => false, 'name' => 'Next') ] }

    it 'halts wizard_too_long' do
      expect { fill! }.to raise_error(Apply::Operation::Engine::Halt) { |halt|
        expect(halt).to have_attributes(code: :wizard_too_long, detail: 'multi-page form')
      }
    end
  end
end
