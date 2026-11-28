# frozen_string_literal: true

# The one row holding the ProxyMate connection an admin entered by hand. It wins over the
# PROXY_MATE_URL / PROXY_MATE_API_KEY ENV variables (kept for dev); ApplyMate::Client::ProxyMate
# reads it once per client. At most one row: unique index on the constant `singleton` column.
class ProxyMateSetting < ApplicationRecord
  KEY_PREVIEW_LENGTH = 9

  encrypts :api_key

  # Find-or-create that is safe against two concurrent first-saves: the loser of the race hits the
  # unique index and just re-reads the winner's row.
  def self.instance
    first || create!
  rescue ActiveRecord::RecordNotUnique
    first!
  end

  # Read-only counterpart for callers that must not create a row (never persisted when absent).
  def self.current
    first || new
  end

  def effective_url
    url.presence || ENV['PROXY_MATE_URL'].presence
  end

  def effective_api_key
    api_key.presence || ENV['PROXY_MATE_API_KEY'].presence
  end

  def api_key_preview
    "#{api_key.first(KEY_PREVIEW_LENGTH)}…" if api_key.present?
  end
end
