# frozen_string_literal: true

# The single reader of the browserd connection settings (see .ai/docs/browser.md):
#   BROWSERD_URL   — control API base, e.g. http://browserd:9300 (staging) / http://localhost:9300 (dev)
#   BROWSERD_TOKEN — Bearer token for every lease route (same value as the browserd container's)
# Both are read at call time, not at boot: web and the general worker never need them, and a missing
# value raises KeyError on the first lease call. There is no fallback driver.
module ApplyMate::Client::Browser::Browserd
  OPEN_TIMEOUT_S = 5
  TIMEOUT_S = 20

  def self.url
    ENV.fetch('BROWSERD_URL') { raise KeyError, 'BROWSERD_URL is not set (browserd control API, e.g. http://localhost:9300)' }
  end

  def self.token
    ENV.fetch('BROWSERD_TOKEN') { raise KeyError, 'BROWSERD_TOKEN is not set (must equal the browserd container token)' }
  end

  # Owner tags are "<hostname>:<app dir>:<env>:<pid>:<apply hashid>"; this prefix is what the apply
  # worker's boot sweep releases. The app dir and env tell apart processes that share a hostname and
  # one browserd: on a dev machine every Conductor workspace (its own Rails.root) and the dev server vs
  # the spec run of one workspace. In a container they are constant (`rails`, the env) and the
  # hostname alone is unique. The trailing colon keeps host "worker" from matching "worker2".
  def self.owner_prefix
    "#{Socket.gethostname}:#{Rails.root.basename}:#{Rails.env}:"
  end

  def self.http
    Faraday.new(
      url:,
      headers: { 'Authorization' => "Bearer #{token}", 'Content-Type' => 'application/json' },
      request: { open_timeout: OPEN_TIMEOUT_S, timeout: TIMEOUT_S }
    )
  end
end
