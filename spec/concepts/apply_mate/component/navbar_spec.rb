# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ApplyMate::Component::Navbar, type: :component do
  let(:user) { create(:user) }

  def navbar(signed_in: true)
    allow(vc_test_controller).to receive_messages(current_user: signed_in ? user : nil, signed_in?: signed_in, impersonating?: false)
    render_inline(described_class.new)
    page.native
  end

  context 'with applies that need attention' do
    before do
      create(:apply, :failed, user:)
      create(:apply, :needs_human, user:)
      create(:apply, :completed, user:)
      Rails.cache.clear
    end

    it 'shows the red count next to "My applies" and links to the attention filter' do
      html = navbar
      links = html.css(%(a[href="/applies?filter=attention"]))

      expect(links.size).to eq(2) # desktop dropdown + mobile menu
      expect(links.first.at_css('span.bg-red-100, span.bg-red-900').text.strip).to eq('2')
    end

    it 'shows a count dot and screen-reader text by the avatar on both bars' do
      html = navbar

      expect(html.css('span.bg-red-600').map { |s| s.text.strip }).to eq(%w[2 2])
      expect(html.css('span.sr-only').map(&:text)).to include(I18n.t('navbar.attention_count', count: 2))
    end
  end

  context 'without applies that need attention' do
    it 'renders the plain link and no counter' do
      create(:apply, :completed, user:)
      Rails.cache.clear
      html = navbar

      expect(html.css('a[href="/applies"]')).not_to be_empty
      expect(html.css('a[href="/applies?filter=attention"]')).to be_empty
      expect(html.css('span.bg-red-600, span.bg-red-100')).to be_empty
    end
  end

  it 'renders no counter for guests' do
    expect(navbar(signed_in: false).css('span.bg-red-600')).to be_empty
  end
end
