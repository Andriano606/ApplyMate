# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Component::VacancyApplyCard, type: :component do
  let(:user)    { create(:user) }
  let(:admin)   { create(:user, :admin) }
  let(:vacancy) { create(:vacancy, source: create(:source)) }

  def card(apply, as: user)
    render_inline(described_class.new(apply:, user: as))
    page.native
  end

  def timeline_details(html)
    html.css('details').find { |d| d.at_css('summary').text.include?(I18n.t('apply.timeline.title')) }
  end

  def attach(record, name, filename)
    record.public_send(name).attach(io: StringIO.new('fake'), filename:, content_type: 'application/octet-stream')
  end

  it 'links the screenshot and the CV through the artifacts route' do
    apply = create(:apply, :completed, user:, vacancy:)
    attach(apply, :screenshot, 'shot.png')
    attach(apply, :cv, 'cv.pdf')
    html = card(apply)

    hrefs = html.css('a').pluck('href')
    expect(hrefs).to include("/artifacts/apply/#{apply.hashid}/screenshot", "/artifacts/apply/#{apply.hashid}/cv?disposition=attachment")
    expect(html.at_css('img')['src']).to eq("/artifacts/apply/#{apply.hashid}/screenshot")
    expect(html.to_s).not_to include('/rails/active_storage')
  end

  it 'shows the failure notice and the exit buttons of a failed apply, with the timeline open' do
    apply = create(:apply, :failed, user:, vacancy:)
    html = card(apply)

    expect(html.text).to include(I18n.t('apply.failure.unexpected_error'), I18n.t('apply.actions.retry'), I18n.t('apply.actions.applied_manually'))
    expect(timeline_details(html).key?('open')).to be(true)
  end

  it 'keeps the timeline closed for a completed apply and shows no failure notice' do
    apply = create(:apply, :completed, user:, vacancy:)
    html = card(apply)

    expect(timeline_details(html).key?('open')).to be(false)
    expect(html.at_css('[role="alert"]')).to be_nil
  end

  it 'shows the technical detail only to admins' do
    apply = create(:apply, :failed, user:, vacancy:, failure: { code: 'stuck', detail: 'secret detail' })

    expect(card(apply).text).not_to include('secret detail')
    expect(card(apply, as: admin).text).to include('secret detail')
  end
end
