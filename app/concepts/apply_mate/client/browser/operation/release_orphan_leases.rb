# frozen_string_literal: true

# DELETE /leases?owner=<prefix> on browserd: kills every active lease whose owner tag starts with the
# prefix. The apply worker calls it once on start (config/initializers/browserd_leases.rb) with
# Browserd.owner_prefix, so leases left by a crashed previous process on this host are freed at once
# instead of by the reaper. Never raises (boot must not depend on browserd): model = released count, or
# nil when browserd is unset / unreachable / answered something unexpected (logged as a warning).
class ApplyMate::Client::Browser::Operation::ReleaseOrphanLeases < ApplyMate::Operation::Base
  include ApplyMate::Logging

  def perform!(owner_prefix:, **)
    skip_authorize
    raise ArgumentError, 'owner_prefix must not be blank (it would release every lease)' if owner_prefix.blank?

    self.model = release(owner_prefix)
  end

  private

  def release(owner_prefix)
    response = ApplyMate::Client::Browser::Browserd.http.delete('/leases', owner: owner_prefix)
    return JSON.parse(response.body).fetch('released') if response.status == 200

    log(event: 'browserd.orphan_sweep_failed', level: :warn, owner_prefix:, status: response.status)
    nil
  rescue Faraday::Error, KeyError, JSON::ParserError, TypeError => e
    log(event: 'browserd.orphan_sweep_failed', level: :warn, owner_prefix:, error: "#{e.class}: #{e.message}")
    nil
  end
end
