# frozen_string_literal: true

# Does the application form live on a site the vacancy led us to? (design §6.4, the `foreign_origin` review reason)
# model = true when the form URL is blank, on a registered platform host (Registry.known_host?), or on a registered
# domain (PublicSuffix) of the entry URL or of any site the detection passed through or landed on (a board redirect,
# the company page); false for a registered domain unrelated to all of those. result[:host] = the form host.
# The one implementation: ReviewReasons and the Navigator both ask it.
class Apply::Operation::Engine::CheckOrigin < ApplyMate::Operation::Base
  def perform!(ctx:, **)
    skip_authorize
    @ctx = ctx
    host = host_of(ctx.form_url)
    result[:host] = host
    self.model = ctx.form_url.blank? || host.nil? || Apply::Platform::Registry.known_host?(host) ||
                 allowed_domains.include?(registered_domain(host))
  end

  private

  attr_reader :ctx

  def allowed_domains
    urls = [ ctx.entry_url, *ctx.evidence&.hops, *ctx.evidence&.current_urls ]
    urls.filter_map { |url| host_of(url) }.map { |host| registered_domain(host) }.uniq
  end

  def host_of(url)
    URI.parse(url.to_s).host&.downcase
  rescue URI::InvalidURIError
    nil
  end

  def registered_domain(host)
    PublicSuffix.domain(host) || host
  end
end
