# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Engine::RecoverField do
  subject(:recover) { described_class.call(ctx:, field:, value: wanted, mismatch:) }

  let(:url) { 'https://acme.example/jobs/1/apply' }
  let(:ctx) { engine_context(create(:apply, entry_url: url)) }
  let(:gemini) { %r{generativelanguage\.googleapis\.com.*generateContent} }
  let(:root) { 'body > form > div:nth-of-type(1)' }
  let(:input_css) { "#{root} > input" }
  let(:wanted) { 'Kyiv Polytechnic Institute' }
  # f0:e0 the field's input, f0:e1 "Enter manually" inside its root, f0:e2 a button of another field
  let(:page_elements) do
    [
      snapshot_element(name: '', css: input_css, regions: [ root ], root_strategies: [ { 'css' => root } ]),
      snapshot_element(role: 'button', name: 'Enter manually', css: "#{root} > button", regions: [ root ]),
      snapshot_element(role: 'button', name: 'Add another', css: 'body > form > div:nth-of-type(2) > button')
    ]
  end
  let(:page) { build_snapshot(frames: [ { url: } ], elements: page_elements) }
  let(:read_values) { { input_css => 'Kyiv' } } # the field keeps showing something else until fixed
  let(:session) { FakeSession.new(html: '', final_url: url, snapshot: page, read_values:) }
  let(:field) do
    answer_field(id: 'school', kind: 'text', widget: 'text', label: 'School', required: true, target: page.elements.first['target'])
  end
  let(:mismatch) do
    Apply::Widget::Mismatch.new(field:, wanted:, read_back: Apply::Widget::Base::ReadBack.new(displayed: 'Kyiv', invalid: false, error_text: nil))
                           .tap { |error| error.before = page }
  end
  let(:prompts) { [] }

  def target_of(ref)
    page.elements.find { |element| element['ref'] == ref }['target']
  end

  def decision(*actions, give_up: false)
    { actions: actions.map { |type, ref| { type:, ref:, key: nil, index: nil, max_ms: nil } }, reason: 'open it', give_up: }
  end

  def ai_answers(*answers)
    responses = answers.map { |answer| gemini_json_response(answer.to_json) }
    stub_request(:post, gemini).to_return do |request|
      prompts << JSON.parse(request.body)['contents'].flat_map { |content| content['parts'] }.pluck('text').join("\n")
      responses.size > 1 ? responses.shift : responses.first
    end
  end

  before { ctx.open_scope!(:survey, session, 10.minutes.from_now) }

  it 'clicks what the AI picked inside the field root, writes again and returns the read-back' do
    session.on(:click) { |target| read_values.delete(input_css) if target == target_of('f0:e1') }
    ai_answers(decision(%w[click f0:e1]))

    expect(recover.model.displayed).to eq(wanted)
    expect(session.calls_of(:click)).to eq([ [ target_of('f0:e1') ] ])
    expect(a_request(:post, gemini)).to have_been_made.once
    expect(ctx.scratch.trace.pluck('event')).to include('recover_turn', 'field_recovered')
    expect(prompts.sole).to include('[f0:e1]', 'Enter manually', 'LABEL: School')
    expect(prompts.sole).not_to include(wanted, 'Add another')
  end

  it 'gives up after MAX_TURNS failing turns, re-raises the last Mismatch and never acts outside the field root' do
    ai_answers(decision(%w[click f0:e2], %w[click f0:e1]))

    expect { recover }.to raise_error(Apply::Widget::Mismatch) { |error|
      expect(error).not_to equal(mismatch)
      expect(error.read_back.displayed).to eq('Kyiv')
    }
    expect(a_request(:post, gemini)).to have_been_made.times(2)
    expect(session.calls_of(:click)).to eq([ [ target_of('f0:e1') ] ] * 2)
    expect(ctx.scratch.trace).to include(a_hash_including('event' => 'action_rejected', 'ref' => 'f0:e2', 'reason' => 'outside_field'))
    expect(prompts.last).to include('click(f0:e2) was rejected: outside_field')
    expect(ctx.scratch.trace.last).to include('event' => 'field_unrecovered', 'field' => 'school')
  end

  it 'stops after one request when the AI gives up, re-raising the original Mismatch without writing' do
    ai_answers(decision(give_up: true))

    expect { recover }.to raise_error(mismatch)
    expect(a_request(:post, gemini)).to have_been_made.once
    expect(session.calls_of(:fill) + session.calls_of(:click)).to be_empty
  end

  it 'lets the AI use an element that appeared outside the root since the write (a portaled menu)' do
    menu = snapshot_element(role: 'option', name: 'Type it yourself', css: 'body > div.portal > div:nth-of-type(1)')
    opened = build_snapshot(frames: [ { url: } ], elements: [ *page_elements, menu ])
    session.show(opened)
    menu_target = opened.elements.last['target']
    session.on(:click) { |target| read_values.delete(input_css) if target == menu_target }
    ai_answers(decision(%w[click f0:e3]))

    expect(recover.model.displayed).to eq(wanted)
    expect(session.calls_of(:click)).to eq([ [ menu_target ] ])
    expect(prompts.sole).to include('*[f0:e3]')
    expect(prompts.sole).not_to include('[f0:e2]')
  end
end
