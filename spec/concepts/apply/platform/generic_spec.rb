# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Platform::Generic do
  let(:ctx) { engine_context(create(:apply)) }
  let(:adapter) { described_class.new(ctx:, match: Apply::Operation::Engine::Detect::Match.generic) }
  let(:evidence) { adapter.success_evidence }

  it 'is ai_only: no readiness poll ever claims a generic page is the form' do
    expect(adapter.readiness).to eq(:ai_only)
    expect(adapter).to be_ai_only
  end

  it 'needs two deterministic signals (one plus the AI corroboration in VerifySubmit), no submit request' do
    expect(evidence).to include(submit_request: nil, min_signals: 2)
  end

  it 'reads thank-you texts in uk, en and ru' do
    [ 'Thank you for applying!', 'Your application has been successfully submitted.', "We've received your CV",
      'Дякуємо за ваш відгук!', 'Вашу заявку успішно надіслано', 'Спасибо за отклик', 'Ваша заявка успешно отправлена' ].each do |text|
      expect(evidence[:texts]).to be_any { |pattern| pattern.match?(text) }, text
    end
    expect(evidence[:texts]).to be_none { |pattern| pattern.match?('Apply for this job') }
  end

  it 'matches thank-you URL fragments in the path or query, never in the host' do
    match = ->(url) { evidence[:url_patterns].any? { |pattern| pattern.match?(url) } }

    expect(match.call('https://acme.example/careers/1/thank-you')).to be(true)
    expect(match.call('https://acme.example/apply?status=success')).to be(true)
    expect(match.call('https://thanks.acme.example/careers/1')).to be(false)
    expect(match.call('https://acme.example/careers/1/apply')).to be(false)
  end
end
