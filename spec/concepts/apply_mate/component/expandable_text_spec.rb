# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ApplyMate::Component::ExpandableText, type: :component do
  let(:html) { '<p>Про нас</p><p><strong>Вимоги</strong></p><ul><li>Ruby</li></ul>' }

  def preview
    page.native.css('summary p').text
  end

  # `strip_tags` inserts no separator between blocks, so deriving the teaser from the
  # markup glues the last word of one paragraph onto the first of the next.
  it "clamps the caller's plain text, not the markup" do
    render_inline(described_class.new(html:, text: "Про нас\n\nВимоги\n\n* Ruby"))

    expect(preview).to include('Про нас')
    expect(preview).not_to include('Про насВимоги')
  end

  it 'expands into the sanitised markup' do
    render_inline(described_class.new(html:, text: 'Про нас'))

    expect(page.native.css('.rich-text li').size).to eq(1)
  end

  it 'renders nothing when neither column has content' do
    render_inline(described_class.new(html: nil, text: ''))

    expect(page.native.css('details')).to be_empty
  end
end
