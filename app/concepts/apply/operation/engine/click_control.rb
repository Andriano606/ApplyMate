# frozen_string_literal: true

# The pointer half of opening a control (ReadComboboxOptions' probe, AriaCombobox's write): click `target`, or, when
# the snapshot found it not visible itself (`target.root` is set only then, SnapshotAll#target) and probe click_box
# reports it has no real box (react-select's DummyInput: 1px, opacity 0, scale(.01)), click its nearest ancestor that
# has one (at most click_box's MAX_DEPTH up). Playwright's visible / stable checks never pass on such an input: the
# plain click burnt the full action timeout and raised Obstructed. The caller keeps `target` for keys and read-back.
# No box anywhere up the chain: the plain click, which raises as before. model = the Target clicked.
class Apply::Operation::Engine::ClickControl < ApplyMate::Operation::Base
  def perform!(ctx:, target:, **)
    skip_authorize
    clicked = pointer_target(ctx.session, target)
    ctx.session.click(clicked)
    self.model = clicked
  end

  private

  def pointer_target(session, target)
    return target if target.root.blank?

    depth = session.probe(:click_box, target)
    return target if depth.nil? || depth.zero?

    target.with(strategies: target.strategies.map { |strategy| strategy.merge('ancestor' => depth) }, root: nil,
                readonly: false)
  end
end
