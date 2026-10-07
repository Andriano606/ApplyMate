# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Component::RunTimeline, type: :component do
  let(:user)  { create(:user) }
  let(:admin) { create(:user, :admin) }
  let(:apply) { create(:apply, user:) }
  let(:t0)    { Time.zone.parse('2026-10-07 10:00:00') }

  def step(attempt:, position:, stage:, state:, **attrs)
    create(:apply_step, apply:, attempt:, position:, key: "#{stage}_#{attempt}", stage:, state:, started_at: t0, **attrs)
  end

  def timeline(as: user)
    render_inline(described_class.new(apply: apply.reload, user: as))
    page.native
  end

  it 'says so when there are no steps' do
    expect(timeline.text).to include(I18n.t('apply.timeline.empty'))
  end

  context 'with two attempts' do
    before do
      step(attempt: 1, position: 0, stage: 'check_applyable', state: :succeeded, finished_at: t0 + 2.seconds)
      step(attempt: 1, position: 1, stage: 'fill_form', state: :failed, finished_at: t0 + 5.seconds,
           error_code: 'invalid_ai_output', error_detail: 'schema mismatch')
      step(attempt: 2, position: 0, stage: 'check_applyable', state: :succeeded, finished_at: t0 + 90.seconds)
      step(attempt: 2, position: 1, stage: 'generate_cv', state: :running)
    end

    it 'shows the newest attempt open and older attempts inside a collapsed accordion' do
      html = timeline

      expect(html.css('ol').size).to eq(2)
      expect(html.at_css('ol').text).to include(I18n.t('apply.stage.generate_cv'))
      accordion = html.at_css('details')
      expect(accordion['open']).to be_nil
      expect(accordion.text).to include(I18n.t('apply.timeline.attempt', n: 1))
      expect(accordion.at_css('ol').text).to include(I18n.t('apply.stage.fill_form'))
    end

    it 'shows durations and a spinner for the running step' do
      html = timeline

      expect(html.text).to include(I18n.t('apply.timeline.duration_seconds', count: 2))
      expect(html.at_css('li[data-step-state="running"] .animate-spin')).to be_present
    end

    it 'shows the failure code text but keeps the detail for admins' do
      expect(timeline.text).to include(I18n.t('apply.failure.invalid_ai_output'))
      expect(timeline.text).not_to include('schema mismatch')
      expect(timeline(as: admin).text).to include('schema mismatch')
    end
  end
end
