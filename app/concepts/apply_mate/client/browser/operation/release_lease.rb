# frozen_string_literal: true

# DELETE /leases/:id on browserd. Called from `ensure` blocks, so it never raises: any failure is
# logged and model = false; browserd's reaper (ws disconnect / TTL) frees the slot anyway.
# model = true when the lease is gone (204, or 404: already reaped).
# The DELETE waits until the browser is dead (≤ 5 s close + 5 s kill + SIGKILL), within Browserd::TIMEOUT_S.
class ApplyMate::Client::Browser::Operation::ReleaseLease < ApplyMate::Operation::Base
  include ApplyMate::Logging

  RELEASED_STATUSES = [ 204, 404 ].freeze

  def perform!(lease:, **)
    skip_authorize
    self.model = release(lease)
  end

  private

  def release(lease)
    response = ApplyMate::Client::Browser::Browserd.http.delete("/leases/#{ERB::Util.url_encode(lease.id)}")
    return true if RELEASED_STATUSES.include?(response.status)

    log(event: 'browserd.release_failed', level: :warn, lease_id: lease.id, status: response.status)
    false
  rescue StandardError => e
    log(event: 'browserd.release_failed', level: :warn, lease_id: lease&.id, error: "#{e.class}: #{e.message}")
    false
  end
end
