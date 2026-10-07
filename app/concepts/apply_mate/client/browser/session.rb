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

  def fill(target, text)
    @driver.fill(locate(target, :required), text)
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

  def probe(name, target, arg = nil)
    @driver.probe(name, locate(target, :attached), arg)
  end

  def present?(target, visibility:)
    locate(target, visibility)
    true
  rescue ApplyMate::Client::Browser::TargetNotFound
    false
  end

  def ready?(root_target, timeout:, min_fields: 1)
    operation::WaitReady.call(driver: @driver, target: root_target, min_fields:,
                              timeout_ms: (timeout.to_f * 1000).to_i).model
  end

  def html(frame_path: [])
    return @driver.content if frame_path.empty?

    probe(:outer_html, ApplyMate::Client::Browser::Target.css(':root', frame_path:))
  end

  def frames
    @driver.frames.map { |frame| { 'url' => frame.url, 'name' => frame.name } }
  end

  def screenshot(full_page: false)
    @driver.screenshot(full_page:)
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

  def network_since(mark)
    @driver.tracker.since(mark)
  end

  private

  def locate(target, visibility)
    operation::Locate.call(driver: @driver, target:, visibility:).model
  end

  def operation
    ApplyMate::Client::Browser::Operation
  end
end
