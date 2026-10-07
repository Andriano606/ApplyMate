# Port of the attached runtime's gotoSmart, behind the PublicAddressGuard:
# ResolvePublicAddress (raises ApplyMate::Net::UnsafeUrlError before any navigation) -> domcontentloaded (30 s)
# -> WaitPastCloudflare (40 s) -> networkidle (8 s, a timeout is fine). Every wait is clamped to the deadline.
# model = NavResult.
class ApplyMate::Client::Browser::Operation::Goto < ApplyMate::Operation::Base
  NAVIGATE_TIMEOUT_MS = 30_000
  CHALLENGE_MAX_MS = 40_000
  NETWORK_IDLE_MS = 8_000

  def perform!(driver:, url:, **)
    skip_authorize
    ApplyMate::Net::Operation::ResolvePublicAddress.call(url:)
    status = driver.navigate(url, timeout_ms: NAVIGATE_TIMEOUT_MS)
    passed, was_challenge = ApplyMate::Client::Browser::Operation::WaitPastCloudflare
                            .call(driver:, max_ms: CHALLENGE_MAX_MS).model
    driver.wait_for_network_idle(timeout_ms: NETWORK_IDLE_MS)
    self.model = ApplyMate::Client::Browser::NavResult.new(status:, final_url: driver.current_url,
                                                           challenge_passed: passed, was_challenge:)
  end
end
