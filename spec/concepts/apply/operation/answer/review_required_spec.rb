# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Answer::ReviewRequired do
  let(:user) { create(:user) }
  let(:answers) { { 'a' => answer_entry('x', source: 'ai', confidence: 0.9) } }
  let(:apply) do
    create(:apply, user:, answers:, entry_url: 'https://dou.ua/goto/vacancy/?id=1', form_url: 'https://jobs.ashbyhq.com/p/1/application')
  end
  let(:ctx) { engine_context(apply) }

  def required
    described_class.call(ctx:)
  end

  it 'is not required for a never-policy user with confident answers on a known origin' do
    expect(required.model).to be(false)
    expect(required[:reasons]).to eq([])
  end

  it 'is required when low confidence forces a review, with the reasons' do
    apply.update!(answers: { 'a' => answer_entry('x', source: 'ai', confidence: 0.2) })

    expect(required.model).to be(true)
    expect(required[:reasons]).to eq([ :low_confidence ])
  end

  it 'is not required once the exact answers were approved' do
    user.update!(review_policy: :always)
    apply.update!(answers_approved_digest: Apply::Operation::Answer::Digest.call(answers:).model)

    expect(required[:reasons]).to eq([ :policy_always ])
    expect(required.model).to be(false)
  end

  it 'is required again when the answers changed after the approval' do
    user.update!(review_policy: :always)
    apply.update!(answers_approved_digest: Apply::Operation::Answer::Digest.call(answers:).model,
                  answers: { 'a' => answer_entry('changed', source: 'ai', confidence: 0.9) })

    expect(required.model).to be(true)
  end
end
