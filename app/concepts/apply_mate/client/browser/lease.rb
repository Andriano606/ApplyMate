# frozen_string_literal: true

# One browserd lease (POST /leases response). The path of `ws_endpoint` is the capability to drive the
# browser, so `inspect`/`to_s` never print it (leases end up in logs and error reports).
ApplyMate::Client::Browser::Lease = Data.define(:id, :ws_endpoint, :expires_at, :playwright_version,
                                                :browser_version) do
  def self.from_json(hash)
    new(
      id: hash.fetch('id'),
      ws_endpoint: hash.fetch('ws_endpoint'),
      expires_at: Time.iso8601(hash.fetch('expires_at')),
      playwright_version: hash.fetch('playwright_version'),
      browser_version: hash.fetch('browser_version')
    )
  end

  def inspect
    "#<Lease id=#{id} expires_at=#{expires_at.iso8601} playwright=#{playwright_version} browser=#{browser_version}>"
  end

  def to_s
    inspect
  end
end
