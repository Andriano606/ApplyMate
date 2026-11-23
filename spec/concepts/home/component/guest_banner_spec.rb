require 'rails_helper'

RSpec.describe Home::Component::GuestBanner, type: :component do
  it 'explains the service with the real job boards and offers Google sign-in' do
    render_inline(described_class.new(source_names: %w[Djinni Dou]))

    expect(page).to have_text(I18n.t('home.guest_banner.title'))
    expect(page).to have_text(I18n.t('home.guest_banner.lead', sources: 'Djinni і Dou'))
    expect(page).to have_css("form[action='/auth/google_oauth2'] button", text: I18n.t('home.guest_banner.cta'))
  end

  it 'falls back to a generic wording when there are no sources yet' do
    render_inline(described_class.new(source_names: []))

    expect(page).to have_text(I18n.t('home.guest_banner.lead', sources: I18n.t('home.guest_banner.sources_fallback')))
  end
end
