# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ApplyMate::Component::RichText, type: :component do
  def rendered(**args)
    render_inline(described_class.new(**args))
    page.native.css('.rich-text').inner_html.strip
  end

  it 'keeps the structure and emphasis the employer wrote' do
    html = rendered(html: '<p>Про нас</p><ul><li>Ruby</li><li>Rails</li></ul>')

    expect(html).to include('<p>Про нас</p>')
    expect(html.scan('<li>').size).to eq(2)
  end

  it 'drops everything outside the allow-list' do
    html = rendered(html: '<p>Про нас</p><script>alert(1)</script><img src="x"><a href="javascript:alert(1)">x</a>')

    expect(html).to include('Про нас')
    expect(html).not_to include('script')
    expect(html).not_to include('<img')
    expect(html).not_to include('javascript:')
  end

  # Compaction has to run *after* sanitisation: a paragraph whose only content is a
  # script has non-blank text while the script is still in it, so the other order
  # keeps the paragraph and then empties it, leaving the gap it meant to close.
  it 'leaves no empty block behind once disallowed tags are removed' do
    expect(rendered(html: '<p>Про нас</p><p><script>alert(1)</script></p><p> </p>')).to eq('<p>Про нас</p>')
  end

  it 'paragraph-wraps the plain text of rows scraped before markup was stored' do
    html = rendered(text: "Перший абзац.\n\nДругий абзац.")

    expect(html).to include('<p>Перший абзац.</p>')
    expect(html).to include('<p>Другий абзац.</p>')
  end

  it 'escapes that plain text rather than trusting it as markup' do
    expect(rendered(text: '<script>alert(1)</script>')).not_to include('<script')
  end

  it 'renders nothing when neither column has content' do
    render_inline(described_class.new(html: '', text: nil))

    expect(page.native.css('.rich-text')).to be_empty
  end
end
