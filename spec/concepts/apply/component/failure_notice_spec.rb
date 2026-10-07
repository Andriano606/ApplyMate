# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Component::FailureNotice, type: :component do
  let(:user)  { create(:user) }
  let(:admin) { create(:user, :admin) }

  def notice(apply, as: user)
    render_inline(described_class.new(apply:, user: as))
    page.native
  end

  context 'with a failed apply' do
    let(:apply) { build(:apply, state: :failed, failure: { code: 'stuck', detail: 'boom at step 3', after_claim: false }) }

    it 'shows the failure title and hint' do
      text = notice(apply).text

      expect(text).to include(I18n.t('apply.failure.stuck'), I18n.t('apply.failure_hint.stuck'))
      expect(text).not_to include(I18n.t('apply.failure_notice.apply_yourself_title'))
    end

    it 'hides the technical detail from regular users' do
      expect(notice(apply).text).not_to include('boom at step 3')
    end

    it 'shows the technical detail to admins' do
      html = notice(apply, as: admin)

      expect(html.at_css('pre').text).to eq('boom at step 3')
      expect(html.text).to include(I18n.t('apply.failure_notice.details_admin'))
    end

    it 'reads string keys too (after a reload)' do
      apply.failure = { 'code' => 'stuck' }

      expect(notice(apply).text).to include(I18n.t('apply.failure.stuck'))
    end
  end

  context 'with a needs_human apply' do
    let(:apply) { build(:apply, :needs_human) }

    it 'uses the apply-yourself heading and the manual_apply_required hint' do
      text = notice(apply).text

      expect(text).to include(I18n.t('apply.failure_notice.apply_yourself_title'), I18n.t('apply.failure_hint.manual_apply_required'))
    end

    it 'shows the 48 h reminder with the closing date once ExpireWaiting reminded this wait' do
      now = Time.current
      apply.assign_attributes(updated_at: now - 2.days, reminded_at: now)
      expected = I18n.t('apply.failure_notice.reminder',
                        date: I18n.l(now - 2.days + Apply::HUMAN_TIMEOUT, format: :short))

      expect(notice(apply).at_css('[data-test-id="apply-wait-reminder"]').text).to eq(expected)
    end

    it 'shows no reminder before ExpireWaiting sent it' do
      apply.updated_at = Time.current
      expect(notice(apply).at_css('[data-test-id="apply-wait-reminder"]')).to be_nil
    end

    it 'keeps a specific reason under the heading' do
      apply.failure = { code: 'captcha_challenge' }

      expect(notice(apply).text).to include(I18n.t('apply.failure_notice.apply_yourself_title'), I18n.t('apply.failure.captcha_challenge'))
    end
  end

  context 'with a failure after the submit claim' do
    it 'warns that the submit may already have happened' do
      apply = build(:apply, :claimed, failure: { code: 'outcome_unknown', after_claim: true })

      expect(notice(apply).text).to include(I18n.t('apply.failure_notice.after_claim_warning'))
    end
  end

  context 'when nothing should be shown' do
    it 'renders nothing for an apply in progress' do
      expect(notice(build(:apply, :running, failure: { code: 'worker_lost' })).text).to be_blank
    end

    it 'renders nothing without a failure' do
      expect(notice(build(:apply, :completed)).text).to be_blank
    end
  end
end
