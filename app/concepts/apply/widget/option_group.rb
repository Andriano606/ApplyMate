# frozen_string_literal: true

# One choice among visible options: radio groups (native or styled, e.g. Ashby's opacity-0 radios under a drawn
# circle), Yes/No answer buttons (aria-pressed) and checkbox groups. The options are read fresh from the field root
# (probe/snapshot.js on the root: names and checked / pressed state); the wanted label is matched with MatchOption
# and clicked through its label, its answer button, or the control itself (scoped to the field root). An option
# already in the wanted state is not clicked (a second click would untick a checkbox). Read-back: the checked /
# pressed option names.
class Apply::Widget::OptionGroup < Apply::Widget::Base
  KINDS = %w[radio_group option_group checkbox_group].freeze
  CHOICE_TYPES = %w[radio checkbox].freeze
  CHOICE_ROLES = %w[radio checkbox switch].freeze
  CHOICE_SELECTOR = ':is(button, [role=button], [role=radio], [role=checkbox], [role=switch], [role=option])'

  def self.handles?(field)
    KINDS.include?(field.kind)
  end

  def settle_kind
    :click
  end

  def write(value)
    options = choices
    wanted = picks(options, value)
    options.each do |option|
      want = wanted.include?(option['name'])
      next if want == option['checked'] || (!want && !field.multi_valued?)

      session.click(option_target(option))
    end
  end

  def read
    raw = session.probe(:read_value, target)
    ReadBack.new(displayed: choices.select { |option| option['checked'] }.pluck('name'), invalid: raw['invalid'] == true,
                 error_text: raw['error_text'])
  end

  def accepts?(read_back, value)
    shown = Array(read_back.displayed)
    wanted = Array(value)
    !read_back.invalid && shown.size == wanted.size &&
      wanted.all? { |label| shown.any? { |name| Apply::Operation::Engine::MatchOption.same?(name, label) } }
  end

  private

  # The option names `value` asks for (one per wanted label); a label no option matches -> Mismatch.
  def picks(options, value)
    names = options.pluck('name')
    labels = field.multi_valued? ? Array(value) : Array(value).first(1)
    labels.map do |label|
      Apply::Operation::Engine::MatchOption.call(candidates: names, wanted: label.to_s).model ||
        raise(Apply::Widget::Mismatch.new(field:, wanted: value, read_back: nil))
    end
  end

  # [{ 'name', 'checked', 'strategies' }] of the choice controls under the field root.
  def choices
    elements = session.probe(:snapshot, root_target).fetch('elements', [])
    elements.select { |element| choice?(element) }.map do |element|
      { 'name' => element['name'].to_s, 'checked' => (element['checked'] || element['pressed']) == true,
        'strategies' => element['strategies'] }
    end
  end

  def choice?(element)
    CHOICE_TYPES.include?(element['type']) || CHOICE_ROLES.include?(element['role']) || element['group'] == 'option_group'
  end

  def root_target
    ApplyMate::Client::Browser::Target.new(frame_path: target.frame_path, strategies: target.root.presence || target.strategies,
                                           root: nil, readonly: false)
  end

  # The option's label, its answer button, then the control itself; the first that matches exactly one element wins
  # (Locate's uniqueness rule), all scoped to the field root.
  def option_target(option)
    name = css_string(option['name'])
    root = root_selector
    labels = scoped_target("#{root} label:text-is(#{name})".strip, "#{root} #{CHOICE_SELECTOR}:text-is(#{name})".strip)
    labels.with(strategies: labels.strategies + Array(option['strategies']))
  end
end
