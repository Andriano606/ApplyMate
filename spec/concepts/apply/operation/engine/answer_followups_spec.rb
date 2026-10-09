# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Engine::AnswerFollowups do
  let(:apply) { create(:apply) }
  let(:ctx) { engine_context(apply) }
  let(:gemini) { %r{generativelanguage\.googleapis\.com.*generateContent} }
  let(:region) { [ 'form#apply' ] }
  let(:page_one) do
    build_snapshot(elements: [
      snapshot_element(role: 'textbox', name: 'Full name', css: '#full_name', required: true, regions: region),
      snapshot_element(role: 'textbox', name: 'Email', type: 'email', css: '#email', required: true, regions: region)
    ])
  end
  let(:page_two) do
    build_snapshot(elements: [
      snapshot_element(role: 'textbox', name: 'Cover letter', tag: 'textarea', css: '#cover', required: true, regions: region),
      snapshot_element(role: 'textbox', name: 'Portfolio URL', type: 'url', css: '#portfolio', regions: region),
      snapshot_element(role: 'button', name: 'Submit application', tag: 'button', type: 'submit', submit_like: true,
                       regions: region)
    ])
  end
  let(:session) { FakeSession.new(html: '', final_url: 'https://careers.acme.example/jobs/7/apply', snapshot: page_two) }
  let(:known) { inventory(page_one) }
  let(:cover_id) { inventory(page_two).first.id }
  let(:portfolio_id) { inventory(page_two).second.id }
  let(:email) { unique_email('jane') }

  def inventory(snapshot)
    Apply::Operation::Engine::BuildFieldInventory.call(ctx:, snapshot:).model
  end

  def followups(page: 2)
    described_class.call(ctx:, page:)
  end

  def stub_answers(payload)
    stub_request(:post, gemini).to_return(gemini_json_response("```json\n#{payload.to_json}\n```"))
  end

  before do
    ctx.adopt_match!(Apply::Operation::Engine::Detect::Match.generic)
    ctx.form_root = ApplyMate::Client::Browser::Target.css('form#apply')
    ctx.open_scope!(:submit, session, 5.minutes.from_now)
    ctx.fields = known
    apply.update!(answers: { known.first.id => answer_entry('Jane Doe', source: 'fact', confidence: 1.0),
                             known.second.id => answer_entry(email, source: 'fact', confidence: 1.0) })
  end

  it 'answers only the new fields, in ONE AI call, and returns the fields on the page now' do
    stub_answers(cover_id => { value: 'Hello', confidence: 0.9 }, portfolio_id => { value: 'https://jane.example', confidence: 0.8 })

    expect(followups.model.map(&:id)).to eq([ cover_id, portfolio_id ])
    expect(a_request(:post, gemini)).to have_been_made.once
    expect(a_request(:post, gemini).with { |req| req.body.include?('Cover letter') && !req.body.include?('Full name') })
      .to have_been_made.once
  end

  it 'persists the fields (earlier pages kept without a target, the new ones with their page) and the merged answers' do
    stub_answers(cover_id => { value: 'Hello', confidence: 0.9 })
    followups

    stored = apply.reload.field_list
    expect(stored.map { |field| [ field.id, field.page, field.target.nil? ] })
      .to eq([ [ known.first.id, nil, true ], [ known.second.id, nil, true ], [ cover_id, 2, false ], [ portfolio_id, 2, false ] ])
    expect(stored.find { |field| field.id == cover_id }.semantic).to eq('cover_letter')
    expect(apply.answers.keys).to contain_exactly(known.first.id, known.second.id, cover_id)
    expect(apply.answers[cover_id]).to eq('value' => 'Hello', 'source' => 'ai', 'confidence' => 0.9)
    expect(ctx.fields.map(&:id)).to eq(stored.map(&:id))
    expect(ctx.scratch.followup_calls).to eq(1)
  end

  it 'never asks again for a new field that already has an answer (an earlier attempt, a review edit)' do
    apply.update!(answers: apply.answers.merge(cover_id => answer_entry('My words', source: 'user', confidence: 1.0),
                                               portfolio_id => answer_entry('https://jane.example', confidence: 0.9)))
    stub_answers({})

    followups

    expect(a_request(:post, gemini)).not_to have_been_made
    expect(apply.reload.answers[cover_id]).to include('value' => 'My words', 'source' => 'user')
  end

  context 'when the page holds only fields the run already knows (a replay after an approved review)' do
    let(:session) { FakeSession.new(html: '', final_url: 'https://careers.acme.example/jobs/7/apply', snapshot: page_one) }

    it 'asks nothing, counts nothing and gives the known fields their fresh targets' do
      stub_answers({})
      ctx.fields = known.map { |field| field.with(target: nil) }

      expect(followups.model.map(&:target)).to eq(known.map(&:target))
      expect(a_request(:post, gemini)).not_to have_been_made
      expect(ctx.scratch.followup_calls).to eq(0)
    end
  end

  it 'halts wizard_too_long once the follow-up answer calls pass MAX_FOLLOWUP_ANSWER_CALLS' do
    stub_answers({})
    ctx.scratch.followup_calls = described_class::MAX_FOLLOWUP_ANSWER_CALLS

    expect { followups }.to raise_error(Apply::Operation::Engine::Halt) { |halt|
      expect(halt).to have_attributes(code: :wizard_too_long, detail: 'follow-up answers')
    }
    expect(a_request(:post, gemini)).not_to have_been_made
  end

  it 'caps the calls at one per wizard page plus two' do
    expect(described_class::MAX_FOLLOWUP_ANSWER_CALLS).to eq(Apply::Operation::Stage::FillFields::MAX_WIZARD_PAGES + 2)
  end
end
