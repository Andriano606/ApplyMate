# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Engine::CheckOrigin do
  subject(:check) { described_class.call(ctx:) }

  let(:entry_url) { 'https://dou.ua/goto/vacancy/?id=1' }
  let(:form_url) { 'https://jobs.ashbyhq.com/preply/1/application' }
  let(:apply) { create(:apply, entry_url:, form_url:) }
  let(:ctx) { engine_context(apply) }

  it 'accepts a known platform host and reports the form host' do
    expect(check.model).to be(true)
    expect(check[:host]).to eq('jobs.ashbyhq.com')
  end

  context 'with a form on an unrelated registered domain' do
    let(:form_url) { 'https://careers.evil-example.com/apply' }

    it 'is false' do
      expect(check.model).to be(false)
      expect(check[:host]).to eq('careers.evil-example.com')
    end
  end

  context 'with the registered domain of the entry url' do
    let(:entry_url) { 'https://www.acme.co.uk/jobs/1' }
    let(:form_url) { 'https://careers.acme.co.uk/apply' }

    it 'accepts any subdomain' do
      expect(check.model).to be(true)
    end
  end

  context 'with a site the detection walked through' do
    let(:form_url) { 'https://hire.partner-site.com/apply' }

    it 'accepts hops and landed URLs' do
      ctx.evidence = Apply::Operation::Engine::Detect::Evidence.build(hops: [ 'https://partner-site.com/job' ],
                                                                      current_urls: [ 'https://other.example.org/x' ])

      expect(check.model).to be(true)
    end
  end

  context 'with a shared public suffix' do
    let(:entry_url) { 'https://acme.co.uk/jobs' }
    let(:form_url) { 'https://evil.co.uk/apply' }

    it 'is not the same site' do
      expect(check.model).to be(false)
    end
  end

  context 'without a form url' do
    let(:form_url) { nil }

    it 'is true' do
      expect(check.model).to be(true)
      expect(check[:host]).to be_nil
    end
  end
end
