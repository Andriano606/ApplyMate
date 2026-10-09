# frozen_string_literal: true

require 'rails_helper'

# Regression on the real Hurma post-submit DOM (kvertus.hurma.work, apply 325): the Generic handler submitted, the page
# showed "Ваша заявка відправлена / Ми розглянемо її найближчим часом" while the form stayed in the DOM, and one 2xx POST
# went to the site. Before the fix: signals 0/2 (no uk feminine forms, no generic submit request).
RSpec.describe Apply::Operation::Engine::VerifySubmit do
  let(:ctx) { engine_context(create(:apply)) }
  let(:html) { file_fixture('apply_engine/hurma/post_submit_success.html').read }
  let(:form_url) { 'https://kvertus.hurma.work/public-vacancies/144?source=NQ==&utm_source=dou_ua' }
  let(:session) { FakeSession.new(html:, final_url: form_url) }
  let(:submit) { { url: 'https://kvertus.hurma.work/api/v1/public/vacancies/144/candidates', method: 'POST', status: 200, at: 1, frame_url: form_url, body: nil, body_error: nil } }
  let(:recaptcha) { { url: 'https://www.google.com/recaptcha/enterprise/clr', method: 'POST', status: 200, at: 1, frame_url: form_url, body: nil, body_error: nil } }
  let(:requests) { [ submit ] }

  before do
    ctx.adopt_match!(Apply::Operation::Engine::Detect::Match.generic)
    ctx.open_scope!(:submit, session, 5.minutes.from_now)
    ctx.form_url = form_url
    ctx.form_root = ApplyMate::Client::Browser::Target.css('form')
    ctx.fields = []
    ctx.scratch.claim_mark = 0
    ctx.scratch.submit_baseline = []
    allow(session).to receive(:network_since).and_return(requests)
  end

  it 'is submitted on the uk thank-you text and the same-site 2xx POST' do
    verdict = described_class.call(ctx:).model

    expect(verdict.status).to eq(:submitted)
    expect(verdict.evidence['signals']).to include('success_text' => true, 'submit_request' => true)
  end

  context 'when the only 2xx POST goes to another site (reCAPTCHA)' do
    let(:requests) { [ recaptcha ] }

    it 'does not count it, so the text alone is not enough' do
      allow(Apply::Operation::Engine::CallAi).to receive(:call).and_raise(StandardError, 'no ai in this example')

      verdict = described_class.call(ctx:).model

      expect(verdict.status).to eq(:unknown)
      expect(verdict.evidence['signals']).to include('success_text' => true, 'submit_request' => false)
    end
  end

  context 'when the page already showed the thank-you text before the click' do
    before { ctx.scratch.submit_baseline = [ 'success_text' ] }

    it 'needs another signal than the request alone' do
      allow(Apply::Operation::Engine::CallAi).to receive(:call).and_raise(StandardError, 'no ai in this example')

      expect(described_class.call(ctx:).model.status).to eq(:unknown)
    end
  end
end
