# frozen_string_literal: true

# HTTP-level detection evidence (design §4.2), before any browser lease: walks the entry URL's redirect chain one
# hop at a time through GuardedFetch (each URL address-checked and pinned, redirects never followed by curl), then
# scans the final page's HTML for script / iframe sources.
#
#   hops          every URL requested, entry first (traced; never scored by Detect)
#   current_urls  [the final URL]
#   script_srcs / iframe_srcs  absolute srcs from the final page; empty when it is not a 2xx HTML page or is a
#                              Cloudflare interstitial (the rendered level redetects after the browser passes it)
#
# A request that fails in curl (timeout, connection reset, TLS) ends the walk at that URL: it becomes the final URL
# without HTML evidence and result[:fetch_error] says why (DetectPlatform traces it). The HTTP level is only a head
# start for the rendered level, so a slow or flaky site must not fail the whole apply here.
#
# Termination: at most MAX_HOPS redirects are followed; a response that redirects again -> Halt(:no_application_path,
# 'redirect loop'). Each request is bounded by the client's --max-time (Context::HTTP_TIMEOUT), so the walk takes at
# most (MAX_HOPS + 1) requests. A Location that is not a URL -> Halt(:no_application_path). A non-public hop raises
# ApplyMate::Net::UnsafeUrlError (Runner: private_address) before it is requested.
class Apply::Operation::Engine::CollectHttpEvidence < ApplyMate::Operation::Base
  MAX_HOPS = 5
  REDIRECT_STATUSES = [ 301, 302, 303, 307, 308 ].freeze
  MAX_SRCS = 200

  def perform!(entry_url:, http:, **)
    skip_authorize
    hops, response = walk(entry_url, http)
    final_url = hops.last
    self.model = Apply::Operation::Engine::Detect::Evidence.build(
      current_urls: [ final_url ], hops:, **sources(response, final_url)
    )
  end

  private

  def walk(url, http)
    hops = []
    loop do
      hops << url
      response = fetch(url, http)
      location = response && location_of(response, url)
      return [ hops, response ] if location.nil?
      raise Apply::Operation::Engine::Halt.new(:no_application_path, detail: 'redirect loop') if hops.size > MAX_HOPS

      url = location
    end
  end

  # nil when curl failed (the walk ends here); UnsafeUrlError is not rescued.
  def fetch(url, http)
    ApplyMate::Net::Operation::GuardedFetch.call(url:, http:).model
  rescue ApplyMate::Client::ImpersonateHttp::RequestError => e
    result[:fetch_error] = "#{e.class.name.demodulize}: #{e.message}".truncate(300)
    nil
  end

  def location_of(response, url)
    return unless REDIRECT_STATUSES.include?(response.status)

    location = Array(response.headers&.fetch('location', nil)).last
    return if location.blank?

    URI.join(url, location.strip).to_s
  rescue URI::Error
    raise Apply::Operation::Engine::Halt.new(:no_application_path, detail: "invalid redirect: #{location.to_s.truncate(200)}")
  end

  def sources(response, base)
    return { script_srcs: [], iframe_srcs: [] } unless html_page?(response)

    doc = Nokogiri::HTML(response.body)
    { script_srcs: absolute(doc.css('script[src]').pluck('src'), base),
      iframe_srcs: absolute(doc.css('iframe[src]').pluck('src'), base) }
  end

  def html_page?(response)
    return false if response.nil?

    response.status.to_i.between?(200, 299) && response.body.present? &&
      !ApplyMate::Client::Response.cloudflare_interstitial?(response.body)
  end

  def absolute(srcs, base)
    srcs.first(MAX_SRCS).filter_map do |src|
      URI.join(base, src.strip).to_s
    rescue URI::Error
      nil
    end
  end
end
