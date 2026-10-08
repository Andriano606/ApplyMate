# frozen_string_literal: true

# A single checkbox: Session#set_checked (attached-only resolution) on the label a person would click when one is
# visible (label[for=id], the wrapping <label>, or a label with the field's text inside its root), else on the input
# itself. A hidden (display: none) or covered (styled, opacity 0 under an svg) checkbox is reachable only through
# its label; Playwright's check on a label sets the label's control. Read-back: `checked`.
class Apply::Widget::NativeCheck < Apply::Widget::Base
  def self.handles?(field)
    field.kind == 'checkbox'
  end

  def settle_kind
    :click
  end

  def write(value)
    session.set_checked(check_target, checked?(value))
  end

  def read
    raw = session.probe(:read_value, target)
    ReadBack.new(displayed: (raw['checked'] == true).to_s, invalid: raw['invalid'] == true, error_text: raw['error_text'])
  end

  def expected_display(value)
    checked?(value).to_s
  end

  # An unticked required checkbox reports :invalid by design, so only the state counts.
  def accepts?(read_back, value)
    read_back.displayed == expected_display(value)
  end

  private

  def checked?(value)
    value == true || Apply::Operation::Engine::MatchOption.truthy?(value)
  end

  def check_target
    label = label_target
    label && session.present?(label, visibility: :required) ? label : target
  end

  def label_target
    id = target.strategies.filter_map { |strategy| strategy.dig('attr', 'id') }.first
    path = target.strategies.filter_map { |strategy| strategy['css'] }.last
    parent = path&.split(' > ')&.then { |segments| segments[0..-2].join(' > ') if segments.size > 1 }
    selectors = [
      ("label[for=#{css_string(id)}]" if id),
      (parent if parent&.split(' > ')&.last&.start_with?('label')),
      ("#{root_selector} label:text-is(#{css_string(field.label)})".strip if field.label.present?)
    ].compact
    scoped_target(*selectors) if selectors.any?
  end
end
