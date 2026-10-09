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

  it 'needs two deterministic signals (one plus the AI corroboration in VerifySubmit)' do
    expect(evidence).to include(min_signals: 2)
  end

  describe 'submit_request' do
    it 'is a 2xx non-GET to the form\'s own registered domain, any body' do
      ctx.form_url = 'https://kvertus.hurma.work/public-vacancies/144?source=NQ=='
      url = evidence.dig(:submit_request, :url)

      expect(evidence[:submit_request]).not_to have_key(:body_ok)
      expect(url).to match('https://kvertus.hurma.work/api/v1/public-vacancies/144/candidates')
      expect(url).to match('https://api.hurma.work/candidates')
      expect(url).not_to match('https://www.google.com/recaptcha/enterprise/clr')
      expect(url).not_to match('https://hurma.work.evil.example/x')
    end

    it 'is nil while the form URL is unknown' do
      ctx.form_url = nil
      allow(ctx.apply).to receive(:form_url).and_return(nil)

      expect(evidence[:submit_request]).to be_nil
    end
  end

  it 'reads thank-you texts in uk, en and ru' do
    [ 'Thank you for applying!', 'Your application has been successfully submitted.', "We've received your CV",
      'Дякуємо за ваш відгук!', 'Вашу заявку успішно надіслано', 'Спасибо за отклик', 'Ваша заявка успешно отправлена',
      'Ваша заявка відправлена', 'Ми розглянемо її найближчим часом', 'Резюме надіслане', 'Анкету прийнято',
      'Ваш отклик отправлен', 'Мы рассмотрим вашу заявку', "We'll review your application" ].each do |text|
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
