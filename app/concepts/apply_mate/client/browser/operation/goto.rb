# Port of the attached runtime's gotoSmart, behind the PublicAddressGuard:
# ResolvePublicAddress (raises ApplyMate::Net::UnsafeUrlError before any navigation) -> domcontentloaded (30 s)
# -> WaitPastCloudflare (40 s) -> settle: network idle, or a form already rendered, whichever comes first (at most
# NETWORK_IDLE_MS; a timeout is fine). Every wait is clamped to the deadline. model = NavResult.
#
# The settle waits network idle in IDLE_SLICE_MS slices and, before each, probes the page (probe/readiness.js under
# body) for RENDERED_FORM_FIELDS visible fillable controls: a server-rendered page whose form is already there is
# usable now, and its beacons / analytics would otherwise hold every landing for the full NETWORK_IDLE_MS.
# Termination: at most NETWORK_IDLE_MS / IDLE_SLICE_MS slices, each clamped to the deadline.
class ApplyMate::Client::Browser::Operation::Goto < ApplyMate::Operation::Base
  NAVIGATE_TIMEOUT_MS = 30_000
  CHALLENGE_MAX_MS = 40_000
  NETWORK_IDLE_MS = 8_000
  IDLE_SLICE_MS = 1_000
  # Visible fillable controls that make a rendered form (fewer is a search or newsletter box); also the engine's
  # default readiness, Engine::WaitReady::DEFAULT_MIN_FIELDS.
  RENDERED_FORM_FIELDS = 3

  def perform!(driver:, url:, **)
    skip_authorize
    ApplyMate::Net::Operation::ResolvePublicAddress.call(url:)
    status = driver.navigate(url, timeout_ms: NAVIGATE_TIMEOUT_MS)
    passed, was_challenge = ApplyMate::Client::Browser::Operation::WaitPastCloudflare
                            .call(driver:, max_ms: CHALLENGE_MAX_MS).model
    settle(driver)
    self.model = ApplyMate::Client::Browser::NavResult.new(status:, final_url: driver.current_url,
                                                           challenge_passed: passed, was_challenge:)
  end

  private

  def settle(driver)
    waited = 0
    while waited < NETWORK_IDLE_MS
      return if form_rendered?(driver)

      slice = [ IDLE_SLICE_MS, NETWORK_IDLE_MS - waited ].min
      return if driver.wait_for_network_idle(timeout_ms: slice)

      waited += slice
    end
  end

  def form_rendered?(driver)
    ApplyMate::Client::Browser::Operation::WaitReady.call(driver:, target: ApplyMate::Client::Browser::Target.css('body'),
                                                          min_fields: RENDERED_FORM_FIELDS, timeout_ms: 0).model
  end
end
