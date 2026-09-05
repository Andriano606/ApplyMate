# frozen_string_literal: true

# rubyonremote.com — a small Ruby/Rails job board (~120 live jobs, 15 per page).
#
# Behind a Cloudflare *managed* challenge, which is a harder problem than Dou's: no
# HTTP client passes it, whatever its TLS fingerprint, and neither does a browser we
# drive. The way through is ApplyMate::Client::Clearance — an unattached Chrome earns
# the cf_clearance cookie once, and every request here then goes out as an ordinary
# AsyncHttp call carrying it (see that class for what was measured).
#
# The listing carries only title/company/location/date, so the description comes from
# each vacancy's own page in the second pass.
class ApplyMate::Scraper::RubyOnRemote < ApplyMate::Scraper::Base
  BASE_URL     = 'https://rubyonremote.com'
  LISTING_URL  = "#{BASE_URL}/remote-jobs/".freeze

  # The clearance is bound to the address that earned it, and the warm-up runs on this
  # host — so the scrape has to run from here too. A pooled proxy would be a different
  # IP holding someone else's token, i.e. a guaranteed 403, and the sync would read
  # that as a dead proxy and burn the shared pool's reputation for Dou and Djinni.
  def self.uses_proxies?
    false
  end

  def self.listing_url(_source)
    LISTING_URL
  end

  # The listing has no descriptions — only the vacancy page does.
  def self.fetches_description?
    true
  end

  def initialize(source, client)
    @source = source
    @client = client
  end

  def fetch_listing(page:)
    url  = "#{LISTING_URL}?page=#{page}"
    doc  = Nokogiri::HTML(get(url).body)
    # Out-of-range pages render the site chrome with no cards at all (measured at
    # page 400), which is the board's only end-of-list signal.
    cards = doc.css('a[href^="/jobs/"]')
    return if cards.empty?

    cards.map { |card| extract_job_data(card) }
  end

  # The employer's own copy, inside the editor markup the board stores it as.
  def fetch_description(url)
    doc  = Nokogiri::HTML(get(url).body)
    node = doc.at_css('div.trix-content')
    return nil if node.nil?

    content_html(node)
  end

  private

  # One request, with the clearance headers this host is only readable through. A
  # request that comes back challenged means the token died before its TTL was up
  # (Cloudflare shortened it, or the exit IP changed), so it is dropped and the next
  # attempt warms a fresh one rather than replaying a dead token for 20 minutes.
  def get(url)
    # Outside the via_proxy block on purpose: it turns every error raised inside into
    # DeadProxyError, which would report a host with no Chrome on it as the site
    # refusing us.
    headers  = clearance_headers(url)
    response = via_proxy { @client.get(url, headers:) }
    return response unless response.cloudflare_challenge?

    ApplyMate::Client::Clearance.forget(url)
    raise DeadProxyError, "#{url} answered with a Cloudflare challenge despite clearance"
  end

  # A challenge that will not clear is not this scraper's to survive: it means the
  # site is refusing this address, which is exactly what DeadProxyError means to the
  # sync. A broken host (no Chrome, no display) is a different failure and must NOT
  # be dressed up as one — it would be reported as the site blocking us and would
  # look, to whoever reads the logs, like a scraping problem instead of a deploy one.
  def clearance_headers(url)
    ApplyMate::Client::Clearance.headers(url)
  rescue ApplyMate::Client::Clearance::ChallengeError => e
    raise DeadProxyError, "no Cloudflare clearance: #{e.message}"
  end

  def extract_job_data(card)
    path        = card['href']
    external_id = path.to_s[%r{/jobs/(\d+)}, 1]

    ApplyMate::Operation::Struct.new(
      source_id: @source.id,
      title: card.at_css('h2')&.text&.strip,
      url: full_url(path),
      company_name: card.at_css('p')&.text&.strip,
      company_icon_url: card.at_css('img')&.[]('src'),
      external_id:
    )
  end
end
