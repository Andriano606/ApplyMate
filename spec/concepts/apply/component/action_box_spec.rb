# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Component::ActionBox, type: :component do
  let(:user)    { create(:user) }
  let(:vacancy) { create(:vacancy, source: create(:source)) }

  def box(apply)
    render_inline(described_class.new(vacancy:, apply:, user:))
    page.native
  end

  it 'invites to apply when there is no apply' do
    expect(box(nil).text).to include(I18n.t('apply.action_box.ready_title'), I18n.t('apply.action_box.apply'))
  end

  it 'shows progress and no exit buttons while in progress' do
    html = box(create(:apply, :running, user:, vacancy:))

    expect(html.text).to include(I18n.t('apply.stage.generate_cv'), I18n.t('apply.action_box.view_progress'))
    expect(html.at_css('[data-test-id="apply-actions"]')).to be_nil
  end

  it 'shows the completed box with apply again' do
    html = box(create(:apply, :completed, user:, vacancy:))

    expect(html.text).to include(I18n.t('apply.action_box.completed'), I18n.t('apply.actions.reapply'))
  end

  it 'shows pill, failure notice and exit buttons for an apply that needs attention' do
    html = box(create(:apply, :needs_human, user:, vacancy:))

    expect(html.text).to include(I18n.t('apply.state.needs_human'), I18n.t('apply.failure_notice.apply_yourself_title'),
                                 I18n.t('apply.actions.open_link'), I18n.t('apply.actions.applied_manually'))
  end

  it 'offers to apply again after a cancel' do
    html = box(create(:apply, state: :cancelled, user:, vacancy:))

    expect(html.text).to include(I18n.t('apply.state.cancelled'), I18n.t('apply.actions.reapply'))
  end

  it 'points a needs_review apply at its card instead of repeating the form' do
    apply = create(:apply, user:, vacancy:, state: :needs_review, failure: { code: 'review', kind: 'human' })
    html = box(apply)

    expect(html.text).to include(I18n.t('apply.state.needs_review'), I18n.t('apply.action_box.review'))
    expect(html.at_css("a[href='#apply_#{apply.hashid}']")).to be_present
  end
end
