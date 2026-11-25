# frozen_string_literal: true

# One search pill. A tag may be a whole boolean expression ('ruby і (backend або frontend)'),
# so the pill shows it the way the search reads it — parsed by the same
# Vacancy::Operation::ParseSearchExpression that BuildSearchQuery uses: phrases as text, the
# і/або operators styled like the toggles between pills, and parentheses only where they change
# the meaning (an OR inside an AND). A plain phrase renders as before. The raw text is the title.
class Vacancy::Component::SearchBar::Tag < ApplyMate::Component::Base
  Expression = Vacancy::Operation::ParseSearchExpression
  OPERATOR_WORDS = (Expression::AND_OPS + Expression::OR_OPS).freeze

  OP_CLASSES = 'text-[10px] font-bold tracking-wider text-indigo-500 dark:text-indigo-300 select-none'
  PAREN_CLASSES = 'font-semibold text-indigo-400 dark:text-indigo-400 select-none'

  def initialize(form:, name:, label:, index:)
    @form = form
    @name = name
    @label = label
    @index = index
  end

  private

  def expression
    node_html(Expression.call(text: @label.to_s).model)
  end

  def node_html(node, parent = nil)
    return phrase_text(node.text) if node.is_a?(Expression::Phrase)

    op = node.is_a?(Expression::And) ? 'and' : 'or'
    # Real spaces around the operator: the flex gap spaces it visually, the spaces keep the text
    # readable when copied or read by a screen reader.
    separator = safe_join([ ' ', content_tag(:span, I18n.t("vacancy.search.#{op}"), class: OP_CLASSES), ' ' ])
    html = safe_join(node.nodes.map { |child| node_html(child, node) }, separator)
    return html unless parent.is_a?(Expression::And) && node.is_a?(Expression::Or)

    safe_join([ content_tag(:span, '(', class: PAREN_CLASSES), html, content_tag(:span, ')', class: PAREN_CLASSES) ])
  end

  # A phrase holding an operator word only exists because it was quoted — keep the quotes,
  # or the pill would read like an operator.
  def phrase_text(text)
    text.split.any? { |word| OPERATOR_WORDS.include?(word.downcase) } ? "\"#{text}\"" : text
  end
end
