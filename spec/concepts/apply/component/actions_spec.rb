# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Component::Actions, type: :component do
  include Rails.application.routes.url_helpers

  let(:vacancy) { create(:vacancy, source: create(:source), url: 'https://dou.ua/vacancy/1', external_url: nil) }

  def labels_for(apply)
    render_inline(described_class.new(apply:))
    page.native.css('a').map { |a| a.text.strip }
  end

  def labels(*keys)
    keys.map { |key| I18n.t("apply.actions.#{key}") }
  end

  it 'offers link, retry, manual and cancel for needs_human' do
    apply = create(:apply, :needs_human, vacancy:)

    expect(labels_for(apply)).to eq(labels('open_link', 'fixed_retry', 'applied_manually', 'cancel'))
  end

  it 'opens the external form when there is one, else the vacancy page, in a new tab' do
    apply = create(:apply, :needs_human, vacancy:)
    apply.update!(external_url: 'https://forms.gle/abc')
    render_inline(described_class.new(apply:))
    link = page.native.at_css('a[target="_blank"]')

    expect(link['href']).to eq('https://forms.gle/abc')
    expect(link['rel']).to include('noopener')

    apply.update!(external_url: nil)
    render_inline(described_class.new(apply: apply.reload))
    expect(page.native.at_css('a[target="_blank"]')['href']).to eq('https://dou.ua/vacancy/1')
  end

  it 'posts to the member routes through Turbo' do
    apply = create(:apply, :needs_human, vacancy:)
    render_inline(described_class.new(apply:))
    html = page.native

    resume = html.at_css(%(a[href="#{resume_apply_path(apply)}"]))
    manual = html.at_css(%(a[href="#{mark_outcome_apply_path(apply, outcome: 'manual')}"]))
    expect(resume['data-turbo-method']).to eq('post')
    expect(resume['data-turbo-stream']).to eq('true')
    expect(manual['data-turbo-confirm']).to eq(I18n.t('apply.actions.applied_manually_confirm'))
    expect(html.at_css(%(a[href="#{cancel_apply_path(apply)}"]))['data-turbo-method']).to eq('post')
  end

  it 'offers no resume for a needs_human apply that already claimed the submit' do
    apply = create(:apply, :needs_human, vacancy:, submit_claimed_at: Time.current)

    expect(labels_for(apply)).to eq(labels('open_link', 'applied_manually', 'cancel'))
  end

  it 'offers no retry for a failed apply whose sibling already submitted to the vacancy' do
    apply = create(:apply, :failed, vacancy:)
    create(:apply, :completed, user: apply.user, vacancy:, source_profile: apply.source_profile)

    expect(labels_for(apply)).to eq(labels('applied_manually', 'cancel'))
  end

  it 'offers retry, manual and cancel for failed' do
    expect(labels_for(create(:apply, :failed, vacancy:))).to eq(labels('retry', 'applied_manually', 'cancel'))
  end

  it 'treats unsupported like needs_human' do
    apply = create(:apply, state: :unsupported, failure: { code: 'closed_posting' }, vacancy:)

    expect(labels_for(apply)).to eq(labels('open_link', 'fixed_retry', 'applied_manually', 'cancel'))
  end

  it 'asks only whether the application went through for submit_unverified' do
    apply = create(:apply, :claimed, vacancy:)

    expect(labels_for(apply)).to eq(labels('sent', 'not_sent'))
    not_sent = page.native.at_css(%(a[href="#{mark_outcome_apply_path(apply, outcome: 'not_sent', confirm: 1)}"]))
    expect(not_sent['data-turbo-confirm']).to eq(I18n.t('apply.mark_outcome.not_sent_warning'))
  end

  it 'offers to apply again for completed and cancelled' do
    expect(labels_for(create(:apply, :completed, vacancy:))).to eq(labels('reapply'))
    expect(labels_for(create(:apply, state: :cancelled, vacancy:))).to eq(labels('reapply'))
  end

  it 'renders nothing while in progress or in review' do
    %i[queued running waiting_capacity needs_review].each do |state|
      render_inline(described_class.new(apply: build(:apply, state:)))
      expect(page.native.text).to be_blank
    end
  end
end
