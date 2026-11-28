# frozen_string_literal: true

class ApplyMate::Scraper::Djinni < ApplyMate::Scraper::Base
  JOB_LIST_URL = 'https://djinni.co/jobs/'

  # The real jobs listing (not the homepage) — what the totals widget links to.
  def self.listing_url(_source)
    JOB_LIST_URL
  end

  def self.proxy_site
    'djinni'
  end

  def initialize(source, client)
    @source = source
    @client = client
  end

  def fetch_listing(page:)
    url      = "#{JOB_LIST_URL}?page=#{page}"
    response = via_proxy { @client.get(url) }
    # Out-of-range pages redirect to /jobs/ — that (and only that) is the real last page.
    return if response.final_url != url && response.final_url == JOB_LIST_URL

    doc   = Nokogiri::HTML(response.body)
    nodes = doc.css('.job-list-item, .job-item')
    # An in-range page ALWAYS has job nodes (the real end redirects, handled above). So a
    # 200 with no nodes and no redirect means the proxy got a rate-limited/blocked page —
    # treat it as a dead proxy so the page is retried on another IP, NOT as the last page.
    # Returning nil here is what truncated Djinni pagination (~6163 of 7746 scraped).
    raise DeadProxyError, 'empty job list (proxy rate-limited)' if nodes.empty?

    nodes.map { |element| extract_job_data(element) }
  end

  private

  def extract_job_data(element)
    title = element.at_css('h2.job-item__position')&.text&.strip
    url = element.at_css('.job-list-item__link, .job_item__header-link, a[href*="/jobs/"]')&.[]('href')
    external_id = url.to_s.scan(/\d+/).first
    description_node = element.at_css('.js-original-text') || element.at_css("#job-description-#{external_id}")
    # Djinni ships the full description inside the listing, so both columns are filled
    # here: the markup as the source wrote it, plus the plain-text projection used by
    # Elasticsearch and the card preview.
    description_html = content_html(description_node)
    description = self.class.to_plain_text(description_html)
    # The company name is the secondary line under the title inside the card header.
    company_name = element.at_css('header .fs-5.text-secondary')&.text&.strip
    company_icon_url = element.at_css('img.userpic-image')&.[]('src')

    ApplyMate::Operation::Struct.new(
      source_id: @source.id,
      title:,
      url: full_url(url),
      description:,
      description_html:,
      company_name:,
      company_icon_url:,
      external_id:
    )
  end
end
