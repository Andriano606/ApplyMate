require 'rails_helper'

RSpec.describe Feedback::Component::Card, type: :component do
  it 'shows the body as plain text, keeping line breaks but no markup' do
    feedback = create(:feedback, body: "Line one\nhi <img src=\"https://evil.example/p.gif\"> <a href=\"https://phish.example\">login</a>")

    render_inline(described_class.new(feedback:))

    expect(page).to have_no_css('article img')
    expect(page).to have_no_css('article a')
    expect(page).to have_text('<a href="https://phish.example">login</a>')
    expect(page.native.css('article br')).to be_present
  end

  it 'colours the rating by sentiment and marks MCP posts' do
    render_inline(described_class.new(feedback: create(:feedback, rating: 3, posted_via: 'mcp')))

    expect(page).to have_css('[data-test-id="feedback-rating"].bg-red-50', text: '3/10')
    expect(page).to have_text(I18n.t('feedback.card.via_mcp'))
  end
end
