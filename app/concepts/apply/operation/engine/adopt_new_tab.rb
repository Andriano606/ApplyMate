# frozen_string_literal: true

# The new-tab rule (design §6.3), ONE implementation for Recipe::Interpret (a recipe's click / press) and
# Engine::ExecuteAction (the Navigator's): after an action that may open a tab, a page beyond the count taken before it
# becomes the session's page through Recipe::Op::SwitchTab (its sign-in host check -> Halt(:login_required) before the
# session moves), traced `new_tab`. The caller observes the new page and records the op.
#
#   watch = AdoptNewTab.watch(ctx, target)             # BEFORE the action: { pages_before:, expect_tab: }
#   ... the action ...
#   tab = AdoptNewTab.call(ctx:, **watch).model         # the performed SwitchTab, or nil
#
# expect_tab (probe/opens_tab.js said the target opens a browsing context): the tab is polled for up to
# SwitchTab::OPEN_TIMEOUT (clamped to the deadline: a browser reports it 0.5-1.5 s after the click); otherwise the
# pages are looked at once. Termination: one bounded wait, at most one switch.
class Apply::Operation::Engine::AdoptNewTab < ApplyMate::Operation::Base
  def self.watch(ctx, target)
    session = ctx.session
    { pages_before: session.pages.size, expect_tab: session.probe(:opens_tab, target) == true }
  end

  def perform!(ctx:, pages_before:, expect_tab: false, **)
    skip_authorize
    pages = new_pages(ctx, pages_before, expect_tab)
    return self.model = nil unless pages

    ctx.check_fence!
    tab = Apply::Recipe::Op::SwitchTab.new(index: pages.size - 1)
    ctx.trace(:new_tab, index: tab.index, url: pages.last['url'])
    tab.perform!(ctx)
    self.model = tab
  end

  private

  def new_pages(ctx, pages_before, expect_tab)
    session = ctx.session
    grown = lambda do
      pages = session.pages
      pages if pages.size > pages_before
    end
    return grown.call unless expect_tab

    session.wait_until(timeout: ctx.clamp(Apply::Recipe::Op::SwitchTab::OPEN_TIMEOUT), &grown) || nil
  end
end
