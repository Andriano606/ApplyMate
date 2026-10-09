# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Engine::ClassifyAdvance do
  let(:ctx) { engine_context(create(:apply)) }
  let(:form_html) { '' }
  let(:html) { "<html><body><h1>Apply</h1><form id=\"apply\">#{form_html}<input id=\"name\"></form></body></html>" }
  let(:outline) { [] }
  let(:elements) { [] }
  let(:snapshot) { build_snapshot(frames: [ { outline: } ], elements:) }
  let(:session) { FakeSession.new(html:, final_url: 'https://careers.acme.example/jobs/1/apply', snapshot:) }

  def button(name, submit_like: false, type: 'button', regions: [ 'form#apply' ], **state)
    snapshot_element(role: 'button', name:, tag: 'button', type:, submit_like:, regions:, **state)
  end

  def classify
    described_class.call(ctx:).model
  end

  before do
    ctx.form_root = ApplyMate::Client::Browser::Target.css('form#apply')
    ctx.open_scope!(:submit, session, 5.minutes.from_now)
  end

  context "with a 'Next' button and 'Step 1 of 2' in the form" do
    let(:form_html) { '<p class="steps">Step 1 of 2</p>' }
    let(:elements) { [ button('Next') ] }

    it 'is :next, even though the probe does not call a type=button submit_like' do
      expect(classify).to have_attributes(kind: :next, name: 'Next', target: snapshot.elements.first['target'])
    end

    it 'traces the kind, the name and the evidence' do
      classify

      expect(ctx.scratch.trace.last).to include('event' => 'advance', 'kind' => 'next', 'name' => 'Next',
                                                'evidence' => [ 'step 1/2' ])
    end
  end

  context "with a submit_like 'Next' and no evidence of a further page" do
    let(:elements) { [ button('Next', submit_like: true, type: 'submit') ] }

    it 'is :final (only Stage::Submit, after the claim, may click a button that might submit)' do
      expect(classify).to have_attributes(kind: :final, name: 'Next')
    end
  end

  context "with a type=button 'Next' and no evidence of a further page" do
    let(:elements) { [ button('Next') ] }

    it 'finds no button' do
      expect(classify).to be_nil
    end
  end

  context "with a 'Continue' button while required schema fields are not on the page yet" do
    let(:elements) { [ button('Continue', submit_like: true, type: 'submit') ] }

    before do
      target = ApplyMate::Client::Browser::Target.css('#name')
      ctx.schema = [ answer_field(id: 'acme:name', required: true), answer_field(id: 'acme:cover', required: true) ]
      ctx.fields = [ answer_field(id: 'acme:name', required: true, target:),
                     answer_field(id: 'acme:cover', required: true, page: 2, target: nil) ]
    end

    it 'is :next' do
      expect(classify).to have_attributes(kind: :next, name: 'Continue')
      expect(ctx.scratch.trace.last['evidence']).to eq([ 'schema field missing: acme:cover' ])
    end
  end

  describe 'schema evidence on a wizard (Field#page, ctx.scratch.wizard_page)' do
    let(:elements) { [ button('Continue', submit_like: true, type: 'submit') ] }
    let(:target) { ApplyMate::Client::Browser::Target.css('#name') }

    before do
      ctx.schema = [ answer_field(id: 'acme:name', required: true), answer_field(id: 'acme:cover', required: true) ]
    end

    it 'is :next while a required schema field was never seen' do
      ctx.fields = [ answer_field(id: 'acme:name', required: true, target:) ]

      expect(classify).to have_attributes(kind: :next)
    end

    it 'is :final on the last page, where the earlier pages\' fields lost their targets (behind, not ahead)' do
      ctx.scratch.wizard_page = 2
      ctx.fields = [ answer_field(id: 'acme:name', required: true, target: nil),
                     answer_field(id: 'acme:cover', required: true, page: 2, target:) ]

      expect(classify).to have_attributes(kind: :final, name: 'Continue')
      expect(ctx.scratch.trace.last['evidence']).to eq([])
    end

    it 'never takes a conditional schema field that is not rendered for a further page' do
      ctx.schema = [ answer_field(id: 'acme:name', required: true),
                     answer_field(id: 'acme:other', required: true, condition: { 'field' => 'acme:name', 'equals' => 'x' }) ]
      ctx.fields = [ answer_field(id: 'acme:name', required: true, target:) ]

      expect(classify).to have_attributes(kind: :final)
    end
  end

  context 'with a step indicator the markup hides (a step kept in the DOM)' do
    let(:form_html) { '<p hidden>Step 1 of 2</p><p style="display: none">Крок 1 з 3</p>' }
    let(:elements) { [ button('Next', submit_like: true, type: 'submit') ] }

    it 'is :final (a hidden indicator is no evidence)' do
      expect(classify).to have_attributes(kind: :final)
    end
  end

  context 'with step indicators that disagree (one of them already shows the last step)' do
    let(:form_html) { '<div class="step">Step 1 of 2</div><div class="step is-active">Step 2 of 2</div>' }
    let(:elements) { [ button('Continue', submit_like: true, type: 'submit') ] }

    it 'is :final: the doubt goes to the claim, never to an unclaimed click' do
      expect(classify).to have_attributes(kind: :final, name: 'Continue')
      expect(ctx.scratch.trace.last['evidence']).to eq([])
    end
  end

  context "with 'Submit application' and 'Step 2 of 2'" do
    let(:form_html) { '<p>Step 2 of 2</p>' }
    let(:elements) { [ button('Back', submit_like: true, type: 'submit'), button('Submit application', submit_like: true, type: 'submit') ] }

    it 'is :final on the submit button' do
      expect(classify).to have_attributes(kind: :final, name: 'Submit application')
    end
  end

  context 'with a progressbar short of its maximum in the frame outline (Ukrainian wizard)' do
    let(:outline) { [ 'h2 Анкета', 'progressbar 1/3' ] }
    let(:elements) { [ button('Назад', submit_like: true, type: 'submit'), button('Наступний крок') ] }

    it 'is :next on the Next button' do
      expect(classify).to have_attributes(kind: :next, name: 'Наступний крок')
    end
  end

  context 'with a step indicator in the outline that shows the last step' do
    let(:outline) { [ 'h2 Крок 3 з 3' ] }
    let(:elements) { [ button('Далі', submit_like: true, type: 'submit') ] }

    it 'is :final' do
      expect(classify).to have_attributes(kind: :final, name: 'Далі')
    end
  end

  context 'with two final-looking buttons' do
    let(:elements) { [ button('Submit application', submit_like: true), button('Send', submit_like: true) ] }

    it 'halts target_not_found' do
      expect { classify }.to raise_error(Apply::Operation::Engine::Halt) { |halt|
        expect(halt).to have_attributes(code: :target_not_found, detail: 'submit buttons in the form: 2')
      }
    end
  end

  context 'without any button in the form' do
    let(:elements) { [ snapshot_element(role: 'textbox', name: 'Name', regions: [ 'form#apply' ]) ] }

    it 'is nil and never reads the page text' do
      expect(classify).to be_nil
      expect(session.calls_of(:html)).to be_empty
    end
  end

  context 'with buttons outside the form, hidden or disabled' do
    let(:form_html) { '<p>Step 1 of 2</p>' }
    let(:elements) do
      [ button('Continue reading', regions: []), button('Next', visible: false),
        button('Submit application', submit_like: true, disabled: true), button('Submit', submit_like: true) ]
    end

    it 'only considers the visible, enabled ones inside the form' do
      expect(classify).to have_attributes(kind: :final, name: 'Submit')
    end
  end

  it 'never takes a word inside another one for a step indicator' do
    expect('homepage 1 of 2').not_to match(described_class::STEP_INDICATOR)
    expect('Сторінка 1 з 4').to match(described_class::STEP_INDICATOR)
  end
end
