# frozen_string_literal: true

# Makes the tab at `index` (of Session#pages, oldest first) the session's page, then waits for its content
# (settle_content). Interpret inserts one after a click that opened a tab; a stored one waits up to OPEN_TIMEOUT for
# its tab (a browser reports a new tab 0.5-1.5 s after the click) and is drift when it never opens. A tab on a sign-in
# host (Gate::SignInWall.oauth_location) -> Halt(:login_required) before the session moves onto it.
class Apply::Recipe::Op::SwitchTab < Apply::Recipe::Op::Base
  OPEN_TIMEOUT = 5

  def self.attributes
    %w[index]
  end

  def self.from_h(attrs)
    new(index: attrs.fetch('index'))
  end

  attr_reader :index

  def initialize(index:)
    raise ArgumentError, "recipe op switch_tab: index must be an Integer >= 0, got #{index.inspect}" unless index.is_a?(Integer) && index >= 0

    @index = index
  end

  def perform!(ctx)
    session = ctx.session
    pages = session.wait_until(timeout: ctx.clamp(OPEN_TIMEOUT)) do
      open = session.pages
      open if open.size > index
    end
    raise Apply::Operation::Recipe::Drift.new(op: self, detail: "tab #{index} never opened") unless pages

    location = Apply::Gate::SignInWall.oauth_location(pages[index]['url'])
    raise Apply::Operation::Engine::Halt.new(:login_required, detail: location) if location

    session.switch_to(index)
    session.settle_content
  end

  def to_h
    head('index' => index)
  end

  def gate_event
    :after_goto
  end
end
