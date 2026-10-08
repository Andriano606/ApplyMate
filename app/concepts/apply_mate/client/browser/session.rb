# The browser facade every apply step uses (design §9.1). One Session = one browserd lease = one fresh Camoufox
# process with one context and one page, open only for the block:
#
#   ApplyMate::Client::Browser::Session.open(deadline: ctx.scope_deadline, owner: Session.owner_for(apply)) do |s|
#     s.goto(url)
#     s.click(Target.css('button', has_text: 'Apply'))
#     s.settle(:click)
#   end
#
# BROWSERD_URL / BROWSERD_TOKEN are required (read by Browserd on first use); there is no other driver and no
# fallback. Elements are addressed by Target and resolved by Operation::Locate with the visibility mode noted per
# method. Actions do not settle implicitly: callers call #settle with the matching profile.
class ApplyMate::Client::Browser::Session
  # Acquires a lease (PoolBusy after AcquireLease::BUSY_ATTEMPTS busy answers), connects, yields, and always
  # releases the lease: the ensure runs when the block raises and when Driver#start fails after the lease was granted.
  def self.open(deadline:, owner:, humanize: false, identity: nil)
    lease = ApplyMate::Client::Browser::Operation::AcquireLease.call(owner:, humanize:, identity:).model
    driver = ApplyMate::Client::Browser::Driver::Playwright.new(lease:, deadline:)
    driver.start
    yield new(driver)
  ensure
    driver&.close
  end

  # "<Browserd.owner_prefix><pid>:<apply hashid>": the apply worker's boot sweep releases leases by that prefix.
  def self.owner_for(apply)
    "#{ApplyMate::Client::Browser::Browserd.owner_prefix}#{Process.pid}:#{apply.hashid}"
  end

  def initialize(driver)
    @driver = driver
  end

  # PublicAddressGuard -> navigate -> Cloudflare wait -> network idle. Raises ApplyMate::Net::UnsafeUrlError
  # before any navigation for a non-public URL.
  def goto(url)
    operation::Goto.call(driver: @driver, url:).model
  end

  def click(target)
    @driver.click(locate(target, :required))
  end

  # Every check #click makes (visible, stable, enabled, not covered by another element) without clicking: raises
  # Obstructed / TargetNotFound exactly where #click would. For a click that cannot be taken back (the submit).
  def trial_click(target)
    @driver.click(locate(target, :required), trial: true)
  end

  def fill(target, text)
    @driver.fill(locate(target, :required), text)
  end

  # Keystrokes with a delay between them (default: a random 40..90 ms per session call), for inputs that ignore
  # #fill and for humanlike typing in the submit scope.
  def type(target, text, delay_ms: rand(40..90))
    @driver.type(locate(target, :required), text, delay_ms:)
  end

  def press(target, key)
    @driver.press(locate(target, :required), key)
  end

  def select(target, value: nil, label: nil)
    @driver.select(locate(target, :required), value:, label:)
  end

  def set_checked(target, value)
    @driver.set_checked(locate(target, :attached), value)
  end

  def upload(target, path, via_chooser: false)
    @driver.upload(locate(target, via_chooser ? :required : :attached), path, via_chooser:)
  end

  def scroll_into_view(target)
    @driver.scroll_into_view(locate(target, :attached))
  end

  def probe(name, target, arg = nil)
    @driver.probe(name, locate(target, :attached), arg)
  end

  # Every frame of the page as one Snapshot (Operation::SnapshotAll); `markers` are the platform registry's DOM
  # marker selectors, counted into evidence[:dom_markers]; `regions` are CSS selectors (form root, excluded panes)
  # each element reports when it sits inside one ('regions').
  def snapshot_all(markers: [], regions: [])
    operation::SnapshotAll.call(driver: @driver, markers:, regions:).model
  end

  # Which listbox options are open now in the target's frame and the top document; pass the result to
  # #wait_for_listbox as `since:` after the action that opens the listbox. option_count is informational.
  def dom_mark(target)
    reads = operation::ReadListbox.call(driver: @driver, frame_path: target.frame_path).model
    containers = reads.transform_values { |scope| scope['containers'] }
    { frame_path: target.frame_path, option_count: containers.values.sum { |counts| counts.values.sum }, containers: }
  end

  # [WaitForListbox::Option(label, target)] new since the mark, or [] after `timeout` seconds (clamped to the
  # deadline). Never raises because nothing opened.
  def wait_for_listbox(since:, timeout:)
    operation::WaitForListbox.call(driver: @driver, since:, timeout_ms: milliseconds(timeout)).model
  end

  # Polls the block every 250 ms until it returns a truthy value (returned) or `timeout` seconds (clamped to the
  # deadline) pass (false).
  def wait_until(timeout:, &condition)
    operation::WaitUntil.call(driver: @driver, timeout_ms: milliseconds(timeout), condition:).model
  end

  def present?(target, visibility:)
    locate(target, visibility)
    true
  rescue ApplyMate::Client::Browser::TargetNotFound
    false
  end

  # Default: at least `min_fields` visible fillable controls under the root. Keys mode (`keys:` + `attr:`): at least
  # ceil(keys.size * ratio) of the keys present in `attr` under the root, any visibility; `key_prefix` (a portable
  # regex source, the platform's per-render prefix) is stripped from each value first.
  def ready?(root_target, timeout:, min_fields: 1, keys: nil, attr: nil, ratio: 0.8, key_prefix: nil)
    operation::WaitReady.call(driver: @driver, target: root_target, min_fields:, keys:, attr:, ratio:, key_prefix:,
                              timeout_ms: milliseconds(timeout)).model
  end

  def html(frame_path: [])
    return @driver.content if frame_path.empty?

    probe(:outer_html, ApplyMate::Client::Browser::Target.css(':root', frame_path:))
  end

  def frames
    @driver.frames.map { |frame| { 'url' => frame.url, 'name' => frame.name } }
  end

  # PNG bytes. mask_fillable paints over every fillable control in every frame (failure artifacts, AI vision).
  def screenshot(full_page: false, mask_fillable: false)
    @driver.screenshot(full_page:, mask: mask_fillable ? @driver.mask_locators : [])
  end

  def cookies
    @driver.cookies
  end

  def current_url
    @driver.current_url
  end

  def settle(kind)
    operation::WaitQuiet.call(tracker: @driver.tracker, profile: kind, deadline: @driver.deadline).model
  end

  def settle_content
    operation::WaitForContentSettle.call(driver: @driver).model
  end

  def network_mark
    @driver.tracker.mark
  end

  # Response bodies of finished non-GET requests matching `pattern` are captured (NetTracker#watch).
  def network_watch(pattern)
    @driver.tracker.watch(pattern)
    nil
  end

  def network_since(mark, bodies: false)
    @driver.tracker.since(mark, bodies:)
  end

  # Non-GET requests started since `mark` that are still in flight (NetTracker#in_flight_since).
  def network_in_flight(mark)
    @driver.tracker.in_flight_since(mark)
  end

  private

  def milliseconds(seconds)
    (seconds.to_f * 1000).to_i
  end

  def locate(target, visibility)
    operation::Locate.call(driver: @driver, target:, visibility:).model
  end

  def operation
    ApplyMate::Client::Browser::Operation
  end
end
