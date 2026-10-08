# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Answer::ReviewReasons do
  let(:user) { create(:user) }
  let(:answers) { { 'a' => answer_entry('x', source: 'ai', confidence: 0.9), 'cv' => answer_entry({ 'file' => 'cv' }, source: 'fact') } }
  let(:apply) do
    create(:apply, user:, answers:, platform: 'ashby', apply_key: 'ashby:preply:1', entry_url: 'https://dou.ua/goto/vacancy/?id=1',
                   form_url: 'https://jobs.ashbyhq.com/preply/1/application')
  end
  let(:ctx) { engine_context(apply) }

  def reasons
    described_class.call(ctx:).model
  end

  it 'is empty for the default user with confident answers on a known origin' do
    expect(user).to be_review_policy_never
    expect(reasons).to eq([])
  end

  it 'lists policy_always for a user who reviews everything' do
    user.update!(review_policy: :always)

    expect(reasons).to eq([ :policy_always ])
  end

  it 'lists unknown_platform only for that policy and an unknown platform' do
    user.update!(review_policy: :unknown_platforms)
    apply.update!(platform: nil)

    expect(reasons).to eq([ :unknown_platform ])
    ctx.adopt_match!(Apply::Operation::Engine::Detect::Match.new(key: 'ashby', confidence: 1.0, captures: {}, frame_path: nil,
                                                                 from_alias: false, probable: nil))
    expect(reasons).to eq([])
  end

  it 'forces review for low confidence even when the policy is never' do
    apply.update!(answers: answers.merge('b' => answer_entry('y', source: 'ai', confidence: 0.3)))

    expect(reasons).to eq([ :low_confidence ])
  end

  it 'ignores a low confidence that is not an AI answer' do
    apply.update!(answers: { 'b' => answer_entry('y', source: 'user', confidence: 0.1) })

    expect(reasons).to eq([])
  end

  it 'lists approximate and consent_pending answers' do
    apply.update!(answers: { 'a' => answer_entry('x', source: 'approximate'), 'c' => answer_entry(true, source: 'policy_pending') })

    expect(reasons).to eq(%i[approximate consent_pending])
  end

  describe 'foreign_origin' do
    it 'is raised for a form on an unrelated registered domain' do
      apply.update!(form_url: 'https://careers.evil-example.com/apply')

      expect(reasons).to eq([ :foreign_origin ])
    end

    it 'accepts a known platform host' do
      expect(reasons).not_to include(:foreign_origin)
    end

    it 'accepts the registered domain of the entry url, whatever the subdomain' do
      apply.update!(entry_url: 'https://www.acme.co.uk/jobs/1', form_url: 'https://careers.acme.co.uk/apply')

      expect(reasons).to eq([])
    end

    it 'accepts a site the detection walked through or landed on' do
      apply.update!(form_url: 'https://hire.partner-site.com/apply')
      ctx.evidence = Apply::Operation::Engine::Detect::Evidence.build(hops: [ 'https://dou.ua/goto/x', 'https://partner-site.com/job' ])

      expect(reasons).to eq([])
    end

    it 'does not treat a shared public suffix as the same site' do
      apply.update!(entry_url: 'https://acme.co.uk/jobs', form_url: 'https://evil.co.uk/apply')

      expect(reasons).to eq([ :foreign_origin ])
    end

    it 'is not raised without a form url' do
      apply.update!(form_url: nil)

      expect(reasons).to eq([])
    end
  end

  describe 'duplicate' do
    before { create(:apply, :completed, user:, apply_key: 'ashby:preply:1') }

    it 'is raised for an earlier submitted apply of the same posting' do
      expect(reasons).to eq([ :duplicate ])
    end

    it 'is not raised once the user confirmed it' do
      apply.update!(duplicate_confirmed_at: Time.current)

      expect(reasons).to eq([])
    end
  end
end
