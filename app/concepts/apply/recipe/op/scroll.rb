# frozen_string_literal: true

# Scrolls a target into view (lazy sections that render on scroll), then settles (:key).
class Apply::Recipe::Op::Scroll < Apply::Recipe::Op::Targeted
  def perform!(ctx)
    ctx.session.scroll_into_view(target)
    ctx.session.settle(settle_kind)
  end

  def settle_kind
    :key
  end
end
