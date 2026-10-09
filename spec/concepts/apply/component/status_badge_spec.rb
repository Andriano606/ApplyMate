# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Component::StatusBadge, type: :component do
  include Rails.application.routes.url_helpers

  let(:user)    { create(:user) }
  let(:vacancy) { create(:vacancy, source: create(:source)) }

  def badge_link(apply)
    render_inline(described_class.new(vacancy:, apply:, user:))
    page.native.at_css("turbo-frame#apply_status_#{vacancy.hashid}_#{user.hashid} a")
  end

  context 'when the user has applied' do
    let(:apply) { create(:apply, :running, user:, vacancy:, stage: 'fill_form') }

    # The badge is itself a turbo-frame (and sits in the 'vacancy-search' frame on the index),
    # so the link has to break out to the full vacancy page.
    it 'links to the apply card on the vacancy page, outside any frame' do
      link = badge_link(apply)

      expect(link['href']).to eq(vacancy_path(vacancy, anchor: "apply_#{apply.hashid}"))
      expect(link['data-turbo-frame']).to eq('_top')
      expect(link.text).to include(I18n.t('apply.stage.fill_form'))
    end
  end

  context 'when the user has not applied' do
    it 'opens the new apply modal' do
      link = badge_link(nil)

      expect(link['href']).to eq(new_apply_path(vacancy_id: vacancy.hashid))
      expect(link['data-turbo-stream']).to eq('true')
      expect(link['data-turbo-frame']).to be_nil
      expect(link.text).to include(I18n.t('apply.new.button'))
    end
  end

  context 'without a preset apply' do
    it 'shows the latest apply of the user for the vacancy' do
      create(:apply, :completed, user:, vacancy:, created_at: 2.days.ago)
      latest = create(:apply, :failed, user:, vacancy:, created_at: 1.day.ago)
      create(:apply, :completed, vacancy:)

      render_inline(described_class.new(vacancy:, user:))

      link = page.native.at_css('a')
      expect(link['href']).to eq(vacancy_path(vacancy, anchor: "apply_#{latest.hashid}"))
      expect(link.text).to include(I18n.t('apply.state.failed'))
    end
  end
end
