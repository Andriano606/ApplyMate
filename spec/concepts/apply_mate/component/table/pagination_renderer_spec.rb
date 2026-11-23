require 'rails_helper'

RSpec.describe ApplyMate::Component::Table::PaginationRenderer, type: :component do
  def render_pagination(page, total_pages)
    collection = WillPaginate::Collection.new(page, 15, total_pages * 15)
    html = with_request_url('/vacancies') do
      vc_test_controller.view_context.will_paginate(collection, renderer: described_class)
    end
    Capybara.string(html.to_s)
  end

  def mobile_items(page, total_pages)
    render_pagination(page, total_pages).all('nav > div.lg\:hidden > *', visible: :all).map(&:text)
  end

  it 'shows only the first, current and last page on phones' do
    expect(mobile_items(5, 120)).to eq(%w[‹ 1 … 5 … 120 ›])
    expect(mobile_items(1, 120)).to eq(%w[‹ 1 … 120 ›])
    expect(mobile_items(120, 120)).to eq(%w[‹ 1 … 120 ›])
  end

  it 'shows the page instead of a gap that would hide a single one' do
    expect(mobile_items(3, 120)).to eq(%w[‹ 1 2 3 … 120 ›])
    expect(mobile_items(2, 3)).to eq(%w[‹ 1 2 3 ›])
  end

  it 'keeps the full windowed list with labelled arrows from lg up' do
    desktop = render_pagination(5, 120).find('nav > div.hidden.lg\:flex', visible: :all)

    expect(desktop).to have_link(I18n.t('will_paginate.next_label').sub('&raquo;', '»'), href: '/vacancies?page=6', visible: :all)
    expect(desktop).to have_link('9', href: '/vacancies?page=9', visible: :all)
    expect(desktop).to have_css('span[aria-current="page"]', text: '5', visible: :all)
  end

  it 'disables the previous arrow on the first page' do
    mobile = render_pagination(1, 120).find('nav > div.lg\:hidden', visible: :all)

    expect(mobile).to have_no_link('‹', visible: :all)
    expect(mobile).to have_css('span.cursor-not-allowed', text: '‹', visible: :all)
  end

  it 'renders nothing for a single page' do
    expect(render_pagination(1, 1)).to have_no_css('nav', visible: :all)
  end
end
