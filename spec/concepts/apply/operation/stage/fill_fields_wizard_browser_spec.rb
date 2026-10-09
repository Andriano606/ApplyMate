# frozen_string_literal: true

require 'rails_helper'

# A two-page wizard (FixtureSite wizard.html: a script re-renders form#apply on Next) through the REAL Session in the
# submit scope: Stage::FillFields fills page 1 with read-back, Engine::ClassifyAdvance calls the type=button Next :next
# ("Step 1 of 2"), Engine::AnswerFollowups discovers the textarea and the consent checkbox and asks the AI (stubbed
# Gemini) for the textarea only, page 2 is filled, "Submit application" is :final; Stage::Submit claims, then posts the
# form exactly once.
RSpec.describe Apply::Operation::Stage::FillFields, :browser do
  let(:apply) { create(:apply) }
  let(:ctx) { engine_context(apply) }
  let(:email) { unique_email('wizard') }
  let(:phone) { unique_phone }
  let(:letter) { 'I would love to run your platform.' }
  let(:gemini) { %r{generativelanguage\.googleapis\.com.*generateContent} }
  # BuildFieldInventory's id of the page-2 textarea ("f_<signature>_<ordinal>"), stable across pages and sessions.
  let(:cover_id) { "f_#{Apply::Field.signature_for(label: 'Cover letter', kind: 'textarea', option_labels: nil)}_0" }
  let(:submit_url) { FixtureSite.url('/submit') }

  def answers_for(fields)
    values = { 'Full name' => 'Jane Doe', 'Email' => email, 'Phone' => phone }
    fields.to_h { |field| [ field.id, answer_entry(values.fetch(field.label), source: 'fact', confidence: 1.0) ] }
  end

  def posts_to_submit(session, mark)
    session.network_since(mark).select { |request| request[:url] == submit_url && request[:method] == 'POST' }
  end

  before do
    ctx.adopt_match!(Apply::Operation::Engine::Detect::Match.generic)
    stub_request(:post, gemini)
      .to_return(gemini_json_response("```json\n#{{ cover_id => { value: letter, confidence: 0.9 } }.to_json}\n```"))
  end

  it 'fills both pages, answers only the follow-up textarea, then claims and posts the form exactly once' do
    on_fixture_form(ctx, FixtureSite.url('/wizard.html'), form_root: 'form#apply', scope: :submit) do |session, fields|
      start = session.network_mark
      ctx.fields = fields
      apply.update!(answers: answers_for(fields))
      expect(fields.map(&:label)).to eq([ 'Full name', 'Email', 'Phone' ])

      filled = described_class.call(ctx:)

      expect(filled[:step_result]).to eq('filled' => 5, 'unfilled' => [], 'pages' => 2)
      expect(ctx.fields.select(&:later_page?).map { |field| [ field.label, field.kind ] })
        .to eq([ [ 'Cover letter', 'textarea' ], [ 'I agree to the privacy policy', 'checkbox' ] ])
      expect(apply.reload.answers[cover_id]).to include('value' => letter, 'source' => 'ai')
      expect(a_request(:post, gemini)).to have_been_made.once
      expect(a_request(:post, gemini).with { |req| req.body.include?('Cover letter') && !req.body.include?('Full name') })
        .to have_been_made.once
      expect(ctx.scratch.trace).to include(include('event' => 'advance', 'kind' => 'next', 'evidence' => [ 'step 1/2' ]),
                                           include('event' => 'advance', 'kind' => 'final', 'name' => 'Submit application'))
      expect(session.probe(:read_value, ctx.fields.find { |field| field.id == cover_id }.target)['value']).to eq(letter)
      expect(posts_to_submit(session, start)).to be_empty

      ctx.scratch.step_record = create(:apply_step, apply:, attempt: ctx.attempt, stage: 'submit')
      Apply::Operation::Stage::Submit.call(ctx:)

      expect(apply.reload.submit_claimed_at).to be_present
      expect(posts_to_submit(session, ctx.scratch.claim_mark).size).to eq(1)
      expect(posts_to_submit(session, start).size).to eq(1)
      expect(session.html).to include('Thank you for applying')
    end
  end

  it 'never advances past page 1 while a required page-1 field is left empty' do
    on_fixture_form(ctx, FixtureSite.url('/wizard.html'), form_root: 'form#apply', scope: :submit) do |_session, fields|
      ctx.fields = fields
      apply.update!(answers: answers_for(fields).except(fields.find { |field| field.label == 'Email' }.id))

      expect { described_class.call(ctx:) }.to raise_error(Apply::Operation::Engine::Halt) { |halt|
        expect(halt).to have_attributes(code: :required_field_unfillable, detail: fields.second.id)
      }
      expect(a_request(:post, gemini)).not_to have_been_made
    end
  end
end
