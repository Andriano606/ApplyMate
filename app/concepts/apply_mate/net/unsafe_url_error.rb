# frozen_string_literal: true

# Raised by ApplyMate::Net::Operation::ResolvePublicAddress when a URL must not be fetched.
# `reason`: :scheme (not an absolute http/https URL), :unresolvable (no address for the host),
# :private (at least one address is loopback / private / link-local / CGNAT / reserved).
# The message names the host only: the full URL may carry tokens from a page or an AI.
class ApplyMate::Net::UnsafeUrlError < StandardError
  REASONS = %i[scheme unresolvable private].freeze

  attr_reader :reason, :url

  def initialize(reason, url:, host: nil)
    raise ArgumentError, "unknown UnsafeUrlError reason #{reason.inspect}" unless REASONS.include?(reason)

    @reason = reason
    @url = url
    super("unsafe URL (#{reason}): host #{host.inspect}")
  end
end
