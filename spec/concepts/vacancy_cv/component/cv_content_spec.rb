# frozen_string_literal: true

require 'rails_helper'

RSpec.describe VacancyCv::Component::CvContent, type: :component do
  let(:user)         { create(:user) }
  let(:vacancy)      { create(:vacancy, source: create(:source)) }
  let(:user_profile) { create(:user_profile, user:, name: 'Backend profile') }

  def attach_cv(record)
    record.cv.attach(io: StringIO.new('%PDF-1.4 fake'), filename: 'cv.pdf', content_type: 'application/pdf')
    record
  end

  def render_card(record)
    render_inline(described_class.new(record:))
    page.native
  end

  context 'with a CV generated during an apply' do
    let(:apply) { attach_cv(create(:apply, user:, vacancy:, user_profile:)) }

    it 'marks it as coming from the apply and links to the apply card' do
      html = render_card(apply)

      frame = html.at_css("turbo-frame#cv_apply_#{apply.hashid}")
      expect(frame).to be_present
      expect(frame.text).to include(I18n.t('vacancy_cv.from_apply'), 'Backend profile')
      expect(frame.at_css(%(a[href="#apply_#{apply.hashid}"])).text).to include(I18n.t('vacancy_cv.go_to_apply'))
    end

    it 'offers the download once the CV is attached' do
      expect(render_card(apply).text).to include(I18n.t('vacancy_cv.download'))
    end
  end

  context 'with an apply still generating its CV' do
    let(:apply) { create(:apply, user:, vacancy:, user_profile:, status: :generating_cv) }

    it 'shows the loading state instead of the download' do
      text = render_card(apply).text

      expect(text).to include(I18n.t('vacancy_cv.from_apply'), I18n.t('vacancy_cv.generating'))
      expect(text).not_to include(I18n.t('vacancy_cv.download'))
    end
  end

  context 'with a manually generated CV' do
    let(:vacancy_cv) { attach_cv(create(:vacancy_cv, vacancy:, user_profile:)) }

    it 'is not marked as coming from an apply and has its own frame id' do
      html = render_card(vacancy_cv)

      expect(html.at_css("turbo-frame#cv_vacancy_cv_#{vacancy_cv.hashid}")).to be_present
      expect(html.text).to include('Backend profile', I18n.t('vacancy_cv.download'))
      expect(html.text).not_to include(I18n.t('vacancy_cv.from_apply'))
      expect(html.css('a[href^="#apply_"]')).to be_empty
    end
  end
end
