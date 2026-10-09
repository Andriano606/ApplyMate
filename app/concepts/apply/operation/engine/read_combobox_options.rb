# frozen_string_literal: true

# The options of a select-like combobox read at discovery (BuildFieldInventory, kind `combobox`, at most
# BuildFieldInventory::MAX_PROBED_COMBOBOXES per inventory), so AnswerFields picks among real options instead of
# 'dynamic': take the listbox mark, click the control, press ArrowDown (Ashby opens only on the keyboard), wait up to
# WAIT s (clamped to the deadline) for the options new since the mark (Session#wait_for_listbox), then close the list:
# CLOSERS in order (Escape; Tab, a blur closes an outside-click menu; one more click, an Alpine toggle ignores both)
# until no option is open any more, each given CLOSE_WAIT s. Nothing is typed and nothing is picked. A list that none
# of them closes stays open: AriaCombobox's later "new since the mark" then sees nothing and the write is a Mismatch.
#
# model = [{ 'label', 'value' }] (label as value, blank / duplicate labels left out, at most MAX_OPTIONS), or nil when
# nothing opened or the control cannot be clicked (gone, covered): the field keeps 'dynamic' options.
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
    session.click(target)
    session.press(target, 'ArrowDown')
    labels = session.wait_for_listbox(since: mark, timeout: ctx.clamp(WAIT)).map(&:label).compact_blank.uniq
    close(mark) if labels.any?
    self.model = labels.first(MAX_OPTIONS).map { |label| { 'label' => label, 'value' => label } }.presence
  rescue ApplyMate::Client::Browser::TargetNotFound, ApplyMate::Client::Browser::Obstructed
    self.model = nil
  end

  private

  attr_reader :ctx, :target

  def session
    ctx.session
  end

  def close(mark)
    CLOSERS.each do |action, *args|
      session.public_send(action, target, *args)
      return if session.wait_until(timeout: ctx.clamp(CLOSE_WAIT)) { closed?(mark) }
    end
  end

  def closed?(mark)
    session.dom_mark(target)[:option_count] <= mark[:option_count]
  end
end
