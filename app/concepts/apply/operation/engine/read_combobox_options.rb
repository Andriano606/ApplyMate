# frozen_string_literal: true

# The options of a select-like combobox read at discovery (BuildFieldInventory, kind `combobox`, at most
# BuildFieldInventory::MAX_PROBED_COMBOBOXES per inventory), so AnswerFields picks among real options instead of
# 'dynamic': take the listbox mark, click the control (Engine::ClickControl: its container when the input has no box),
# press ArrowDown (Ashby opens only on the keyboard), wait up to
# WAIT s (clamped to the deadline) for the options new since the mark (Session#wait_for_listbox), then close the list:
# CLOSERS in order (Escape; Tab, a blur closes an outside-click menu; one more click, an Alpine toggle ignores both)
# until no option is open any more, each given CLOSE_WAIT s. Nothing is typed and nothing is picked. A list that none
# of them closes stays open: AriaCombobox's later "new since the mark" then sees nothing and the write is a Mismatch.
# The list is closed whenever options showed OR the control still says aria-expanded="true" (probe read_value
# `expanded`): a search-driven combobox (an async geocoder) opens an EMPTY menu that would otherwise stay over the
# controls below it.
#
# model = [{ 'label', 'value' }] (label as value, blank / duplicate labels left out), or nil when nothing opened, the
# control cannot be clicked (gone, covered) or the list is longer than MAX_OPTIONS: the field keeps 'dynamic' options.
# A long list (countries, cities, languages) is never stored cut: CoerceValue and MatchOption treat an Array as the
# complete set and would refuse every answer past the cut ("Ukraine" in a 244-country list); as 'dynamic' the answer
# is taken as given and AriaCombobox types it to filter the list at fill time.
class Apply::Operation::Engine::ReadComboboxOptions < ApplyMate::Operation::Base
  WAIT = 2
  CLOSE_WAIT = 0.5
  CLOSERS = [ [ :press, 'Escape' ], [ :press, 'Tab' ], [ :click ] ].freeze
  # Every key this probe presses: none of them submits or types (SmokeSurvey's read-only contract allows exactly these).
  KEYS = %w[ArrowDown Escape Tab].freeze
  MAX_OPTIONS = 100

  def perform!(ctx:, target:, **)
    skip_authorize
    @ctx = ctx
    @target = target
    mark = session.dom_mark(target)
    @clicked = Apply::Operation::Engine::ClickControl.call(ctx:, target:).model
    session.press(target, 'ArrowDown')
    labels = session.wait_for_listbox(since: mark, timeout: ctx.clamp(WAIT)).map(&:label).compact_blank.uniq
    close(mark) if labels.any? || expanded?
    self.model = labels.map { |label| { 'label' => label, 'value' => label } }.presence if labels.size <= MAX_OPTIONS
  rescue ApplyMate::Client::Browser::TargetNotFound, ApplyMate::Client::Browser::Obstructed
    self.model = nil
  end

  private

  attr_reader :ctx, :target, :clicked

  def session
    ctx.session
  end

  def expanded?
    session.probe(:read_value, target)['expanded'] == true
  end

  def close(mark)
    CLOSERS.each do |action, *args|
      session.public_send(action, action == :click ? clicked : target, *args)
      return if session.wait_until(timeout: ctx.clamp(CLOSE_WAIT)) { closed?(mark) }
    end
  end

  def closed?(mark)
    session.dom_mark(target)[:option_count] <= mark[:option_count]
  end
end
