# frozen_string_literal: true

# The one PublicAddressGuard (design §9.3): every fetch of a URL that came from a page, an AI or a
# redirect goes through it before the request is made. Raises ApplyMate::Net::UnsafeUrlError unless the
# URL is http(s) and EVERY address its host resolves to is public; a mix of public and private
# answers is rejected too (DNS-rebinding defence: the client may connect to any of them).
#
# model = Resolution with the first (public) address. `ip` exists so phase 3a's DetectPlatform can pin
# ImpersonateHttp to the checked address via curl `--resolve`; no phase-2 caller needs that yet.
#
# Cost: literal IPs never hit DNS; a hostname is resolved via /etc/hosts, then DNS with a 3 s timeout
# per attempt (Resolv::DNS retries per search domain / nameserver, so a dead resolver is bounded, not
# instant).
class ApplyMate::Net::Operation::ResolvePublicAddress < ApplyMate::Operation::Base
  Resolution = Data.define(:url, :host, :port, :ip)

  SCHEMES = %w[http https].freeze
  DNS_TIMEOUT_S = 3

  # IPv4-mapped IPv6 (::ffff:0:0/96) is not listed: it is unwrapped and its IPv4 checked instead.
  BLOCKED_RANGES = %w[
    0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.0.0.0/24
    192.168.0.0/16 198.18.0.0/15 224.0.0.0/4 240.0.0.0/4
    ::/128 ::1/128 fc00::/7 fe80::/10
  ].map { |range| IPAddr.new(range) }.freeze

  def perform!(url:, **)
    skip_authorize

    uri = parse!(url)
    addresses = resolve(uri.hostname)
    raise ApplyMate::Net::UnsafeUrlError.new(:unresolvable, url:, host: uri.hostname) if addresses.empty?
    raise ApplyMate::Net::UnsafeUrlError.new(:private, url:, host: uri.hostname) unless all_public?(addresses)

    self.model = Resolution.new(url: uri.to_s, host: uri.hostname, port: uri.port, ip: addresses.first.to_s)
  end

  private

  def parse!(url)
    uri = URI.parse(url.to_s)
    return uri if SCHEMES.include?(uri.scheme&.downcase) && uri.hostname.present?

    raise ApplyMate::Net::UnsafeUrlError.new(:scheme, url:, host: uri.hostname)
  rescue URI::InvalidURIError
    raise ApplyMate::Net::UnsafeUrlError.new(:scheme, url:)
  end

  def resolve(host)
    literal = literal_address(host)
    return [ literal ] if literal

    resolver.getaddresses(host).map { |address| literal_address(address.to_s) }
  end

  def literal_address(host)
    IPAddr.new(host)
  rescue IPAddr::InvalidAddressError
    nil
  end

  def resolver
    Resolv.new([ Resolv::Hosts.new, Resolv::DNS.new.tap { |dns| dns.timeouts = DNS_TIMEOUT_S } ])
  end

  # An answer IPAddr cannot parse (e.g. a scoped `fe80::1%lo` from /etc/hosts) is nil and counts as
  # not public: fail closed.
  def all_public?(addresses)
    addresses.all? { |address| address && public_address?(address) }
  end

  def public_address?(address)
    address = address.native if address.ipv4_mapped?
    BLOCKED_RANGES.none? { |range| range.family == address.family && range.include?(address) }
  end
end
