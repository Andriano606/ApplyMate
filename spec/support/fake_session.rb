# frozen_string_literal: true

# A scripted stand-in for ApplyMate::Client::Browser::Session in step specs (no browserd, no Playwright). Same
# public methods and parameters as Session (spec/concepts/apply_mate/client/browser/session_contract_spec.rb keeps
# them in sync); every call is recorded in #calls as [method, *positional args, kwargs hash (when any)]:
#
#   let(:session) { FakeSession.new(html: page_html, final_url: url) }
#   before { stub_browser_session(session) }
#   expect(session.calls).to include([ :goto, url ], [ :settle, :click ])
#   expect(session.open_options.sole).to include(humanize: true)
#
# Locating: a target whose FIRST strategy's css is listed in `missing` is not on the page (click / fill / press /
# select / set_checked / upload / probe raise TargetNotFound, present? is false); everything else is found.
# probe(:read_value, target) echoes the last value filled/selected into that target unless `read_values` (keyed
# by that css) overrides it. `on(:click) { |target, *| ... }` runs a hook before the call is handled (to look at
# the DB mid-step, or raise).
class FakeSession
  attr_reader :calls, :open_options

  def initialize(html:, final_url:, cookies: '', read_values: {}, missing: [])
    @html = html
    @final_url = final_url
    @cookies = cookies
    @read_values = read_values
    @missing = missing
    @filled = {}
    @hooks = Hash.new { |hash, key| hash[key] = [] }
    @calls = []
    @open_options = []
  end

  def on(method, &block)
    @hooks[method] << block
    self
  end

  # Calls of `method`, without the method name.
  def calls_of(method)
    calls.select { |call| call.first == method }.map { |call| call.drop(1) }
  end

  def goto(url)
    record(:goto, url)
    ApplyMate::Client::Browser::NavResult.new(status: 200, final_url: @final_url, challenge_passed: true,
                                              was_challenge: false)
  end

  def click(target)
    record(:click, target)
    locate!(target)
    nil
  end

  def fill(target, text)
    record(:fill, target, text)
    locate!(target)
    @filled[target] = text
    nil
  end

  def press(target, key)
    record(:press, target, key)
    locate!(target)
    nil
  end

  def select(target, value: nil, label: nil)
    record(:select, target, value:, label:)
    locate!(target)
    @filled[target] = value || label
    nil
  end

  def set_checked(target, value)
    record(:set_checked, target, value)
    locate!(target)
    nil
  end

  def upload(target, path, via_chooser: false)
    record(:upload, target, path, via_chooser:)
    locate!(target)
    nil
  end

  def probe(name, target, arg = nil)
    record(:probe, name, target, *[ arg ].compact)
    locate!(target)
    case name
    when :read_value then read_value(target)
    when :outer_html then @html
    end
  end

  def present?(target, visibility:)
    record(:present?, target, visibility:)
    !missing?(target)
  end

  def ready?(root_target, timeout:, min_fields: 1)
    record(:ready?, root_target, timeout:, min_fields:)
    !missing?(root_target)
  end

  def html(frame_path: [])
    record(:html, frame_path:)
    @html
  end

  def frames
    record(:frames)
    [ { 'url' => @final_url, 'name' => '' } ]
  end

  def screenshot(full_page: false)
    record(:screenshot, full_page:)
    ''
  end

  def cookies
    record(:cookies)
    @cookies
  end

  def current_url
    record(:current_url)
    @final_url
  end

  def settle(kind)
    record(:settle, kind)
    { quiet: true, ms: 0 }
  end

  def settle_content
    record(:settle_content)
    true
  end

  def network_mark
    record(:network_mark)
    0
  end

  def network_since(mark)
    record(:network_since, mark)
    []
  end

  private

  def record(method, *args, **kwargs)
    call = [ method, *args ]
    call << kwargs if kwargs.any?
    @calls << call
    @hooks[method].each { |hook| hook.call(*args, **kwargs) }
  end

  def first_css(target)
    target.strategies.first&.fetch('css', nil)
  end

  def missing?(target)
    @missing.include?(first_css(target))
  end

  def locate!(target)
    raise ApplyMate::Client::Browser::TargetNotFound.new(target) if missing?(target)
  end

  def read_value(target)
    value = @read_values.fetch(first_css(target)) { @filled[target] }
    { 'tag' => 'input', 'value' => value, 'checked' => nil, 'files' => [], 'text' => '' }
  end
end

module FakeSessionHelpers
  # Makes ApplyMate::Client::Browser::Session.open yield `fake` (and return the block's value, like the real
  # one) and appends each call's kwargs to fake.open_options. verify_partial_doubles checks the kwargs against
  # the real Session.open signature.
  def stub_browser_session(fake)
    allow(ApplyMate::Client::Browser::Session).to receive(:open) do |**options, &block|
      fake.open_options << options
      block.call(fake)
    end
  end
end

RSpec.configure { |config| config.include FakeSessionHelpers }
