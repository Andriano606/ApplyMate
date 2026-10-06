# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Component::FilledFormPreview, type: :component do
  let(:filled_inputs) { [ { 'name' => 'resume', 'tag' => 'input', 'type' => 'file', 'label' => 'Attach CV' } ] }

  def render_preview(cv_attached:)
    render_inline(described_class.new(filled_inputs:, cv_attached:))
    page.native
  end

  it 'shows a sent file field as attached instead of a native "No file chosen" input' do
    html = render_preview(cv_attached: true)

    expect(html.at_css('input[type="file"]')).to be_nil
    expect(html.at_css('[aria-label="Attach CV"]').text).to include(I18n.t('apply.card.cv_attached'))
  end

  it 'says no resume was attached when the apply has none' do
    html = render_preview(cv_attached: false)

    expect(html.at_css('[aria-label="Attach CV"]').text).to include(I18n.t('apply.card.cv_not_attached'))
  end
end
