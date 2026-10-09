# frozen_string_literal: true

# A gate (design §10.4): a known obstacle checked at fixed engine events. Declarative and thin: it reads the event's
# evidence / snapshot (Operation::Engine::RunGates passes both) and either returns nil (not present), resolves the
# obstacle in place and returns truthy (cookie banner), or raises Apply::Operation::Engine::Halt.
#
#   http_resolved  after the HTTP redirect walk, before any browser (evidence only)
#   after_goto     after a navigation; after_action after a click / fill; before_submit right before the claim;
#   after_submit   after the submit click (snapshot + evidence of the current page)
#
# A gate stops ONE apply; it never writes shared state (pools, reputations, recipes).
class Apply::Gate::Base
  EVENTS = %i[http_resolved after_goto after_action before_submit after_submit].freeze

  def self.events
    raise NotImplementedError, "#{name} must declare events"
  end

  # "host/path" of `url` (lowercase host without "www."), nil when it has no host.
  def self.host_path(url)
    uri = URI.parse(url.to_s)
    uri.host && "#{uri.host.downcase.delete_prefix('www.')}#{uri.path}"
  rescue URI::InvalidURIError
    nil
  end

  # ctx: the run's Context; event: one of EVENTS; evidence: Detect::Evidence; snapshot: Browser::Snapshot or nil.
  def call(_ctx, **)
    raise NotImplementedError, "#{self.class} must define call"
  end

  private

  def halt!(code, detail: nil)
    raise Apply::Operation::Engine::Halt.new(code, detail:)
  end

  # The page the run is on: the final URL (http level) or the top frame's URL (rendered; frame_urls list it first).
  def main_url(evidence)
    evidence.current_urls.first
  end

  def host(url)
    URI.parse(url.to_s).host&.downcase
  rescue URI::InvalidURIError
    nil
  end

  # True when `host` is one of `domains` or a subdomain of one.
  def on_domain?(host, domains)
    host.present? && domains.any? { |domain| host == domain || host.end_with?(".#{domain}") }
  end
end
