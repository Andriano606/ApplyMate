# frozen_string_literal: true

# Clicks a target inside Engine::GuardAction (gates before the click, one retry when obstructed), then settles
# (:click). A click may open a tab: Interpret follows it (opens_tab?).
class Apply::Recipe::Op::Click < Apply::Recipe::Op::Targeted
  def perform!(ctx)
    Apply::Operation::Engine::GuardAction.call(ctx:, action: -> { ctx.session.click(target) })
    ctx.session.settle(settle_kind)
  end

  def settle_kind
    :click
  end

  def opens_tab?
    true
  end
end
