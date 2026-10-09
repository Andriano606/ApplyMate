# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Component::Index, type: :component do
  let(:user) { create(:user) }

  def render_index(filter: nil, attention_count: 2)
    applies = create_list(:apply, 1, :failed, user:).then { |list| Apply.where(id: list).includes(:vacancy, :user_profile, :ai_integration) }
    render_inline(described_class.new(applies:, filter:, attention_count:))
    page.native
  end

  before do
    allow(vc_test_controller).to receive_messages(current_user: user, signed_in?: true, impersonating?: false)
  end

  it 'renders the all and attention tabs with the count' do
    tabs = render_index.css('[data-test-id="apply-filter-tabs"] a')

    expect(tabs.map { |a| a.text.strip }).to eq([ I18n.t('apply.index.filter.all'), I18n.t('apply.index.filter.attention', count: 2) ])
    expect(tabs.pluck('href')).to eq([ '/applies', '/applies?filter=attention' ])
  end

  it 'marks the active tab' do
    tabs = render_index(filter: 'attention').css('[data-test-id="apply-filter-tabs"] a')

    expect(tabs.last['class']).to include('border-indigo-600')
    expect(tabs.first['class']).not_to include('border-indigo-600')
  end

  it 'shows the failure reason of rows that need attention' do
    expect(render_index.text).to include(I18n.t('apply.index.table.failure'), I18n.t('apply.failure.unexpected_error'))
  end
end
