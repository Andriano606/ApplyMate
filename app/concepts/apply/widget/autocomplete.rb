# frozen_string_literal: true

# A typeahead text input (role=combobox + aria-autocomplete list/both, no select chrome: BuildFieldInventory's
# `autocomplete` kind): its suggestions appear only once something is typed, no ArrowDown. For each of PREFIXES
# (the first characters of the answer): click, clear, take the listbox mark, type the prefix, wait up to MAX_WAIT s for
# the options that are new since the mark (the field's frame and the top document: portaled menus count) and click
# the MatchOption match. The mark is taken AFTER clearing: clearing closes the previous prefix's suggestions, so the
# next ones all count as new.
#
# Nothing matches after the last prefix but there are suggestions -> the FIRST one is clicked and kept as
# #approximate_pick (SetFieldValue -> result[:approximate] -> FillFields stores an `approximate` answer, and the review
# reason `approximate` stops the run before the claim). No suggestion at all -> Mismatch. Read-back: the chip or the
# input value (read_value.js), compared with the picked option label.
class Apply::Widget::Autocomplete < Apply::Widget::Base
  PREFIXES = [ 10, 4 ].freeze
  MAX_WAIT = 5

  attr_reader :approximate_pick

  def self.handles?(field)
    field.kind == 'autocomplete'
  end

  def settle_kind
    :click
  end

  def write(value)
    @picked = @approximate_pick = nil
    wanted = value.to_s
    prefixes = PREFIXES.map { |length| wanted.first(length) }.uniq
    prefixes.each_with_index do |prefix, index|
      options = suggest(prefix)
      next if options.empty?

      option = matching(options, wanted) || (approximate(options.first) if index == prefixes.size - 1)
      next if option.nil?

      @picked = option.label
      return session.click(option.target)
    end
    raise Apply::Widget::Mismatch.new(field:, wanted: value, read_back: nil)
  end

  def expected_display(value)
    @picked || value.to_s
  end

  private

  def suggest(prefix)
    session.click(target)
    session.fill(target, '')
    mark = session.dom_mark(target)
    session.type(target, prefix)
    session.wait_for_listbox(since: mark, timeout: ctx.clamp(MAX_WAIT))
  end

  def matching(options, wanted)
    label = Apply::Operation::Engine::MatchOption.call(candidates: options.map(&:label), wanted:).model
    label && options.find { |option| option.label == label }
  end

  def approximate(option)
    @approximate_pick = option.label
    option
  end
end
