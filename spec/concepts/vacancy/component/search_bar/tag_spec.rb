require 'rails_helper'

RSpec.describe Vacancy::Component::SearchBar::Tag, type: :component do
  def pill_labels(include_tags:, exclude_tags: [])
    render_inline(Vacancy::Component::SearchBar.new(include_tags:, include_ops: [ 'and' ] * (include_tags.size - 1),
                                                    exclude_tags:))
    page.all('[data-test-id="search-pill-label"]')
  end

  it 'renders a plain phrase as before' do
    label = pill_labels(include_tags: [ 'ruby on rails' ]).sole

    expect(label.text.squish).to eq('ruby on rails')
    expect(label).to have_no_css('span')
  end

  it 'shows an expression tag with its operators, and parentheses where an OR sits inside an AND' do
    label = pill_labels(include_tags: [ 'ruby and ("backend developer" or "back-end engineer")' ]).sole

    and_word = I18n.t('vacancy.search.and')
    or_word  = I18n.t('vacancy.search.or')
    expect(label.text.squish).to eq("ruby #{and_word} (backend developer #{or_word} back-end engineer)")
    expect(label).to have_css('span', text: and_word, count: 1)
    expect(label).to have_css('span', text: '(', count: 1)
  end

  it 'adds no parentheses where precedence already reads right' do
    label = pill_labels(include_tags: [ 'rails and remote or ruby' ]).sole

    expect(label.text.squish).to eq("rails #{I18n.t('vacancy.search.and')} remote #{I18n.t('vacancy.search.or')} ruby")
    expect(label).to have_no_css('span', text: '(')
  end

  it 'keeps the quotes of a phrase that is an operator word, and the raw tag as the title' do
    pill_labels(include_tags: [ '"і" or та' ])

    expect(page).to have_css('[title="\"і\" or та"]')
    expect(page.find('[data-test-id="search-pill-label"]').text).to start_with('"і"')
  end

  it 'escapes markup in the tag' do
    pill_labels(include_tags: [ '<b>ruby</b> or rails' ])

    expect(page).to have_no_css('[data-test-id="search-pill-label"] b')
    expect(page).to have_text('<b>ruby</b>')
  end

  it 'renders exclude tags the same way' do
    labels = pill_labels(include_tags: [ 'rails' ], exclude_tags: [ 'junior or intern' ])

    expect(labels.last.text.squish).to eq("junior #{I18n.t('vacancy.search.or')} intern")
  end
end
