# frozen_string_literal: true

class ApplyMate::Scraper::Dou < ApplyMate::Scraper::Base
  VACANCIES_URL = 'https://jobs.dou.ua/vacancies/'
  XHR_URL       = 'https://jobs.dou.ua/vacancies/xhr-load/'

  def initialize(source = Source.find_by(name: 'Dou'), client = ApplyMate::Client::Http.new)
    @source = source
    @client = client
  end

  def fetch_description(url)
    html = @client.fetch_body(url)
    return nil if html.blank?

    doc  = Nokogiri::HTML(html)
    node = doc.at_css('div.l-vacancy')
    return nil if node.nil?

    sanitize_html(node.inner_html, compact: true)
  end

  def fetch_details(url)
  end

  def form_selector
    'form#replied-id'
  end

  def fetch_applyble(url, session_id:)
    headers = session_id.present? ? { 'Cookie' => "sessionid=#{session_id}" } : {}
    html    = @client.get(url, headers:)&.body
    return false if html.blank?

    doc = Nokogiri::HTML(html)
    doc.at_css('a.replied-external').present? || doc.at_css('a#reply-btn-id').present?
  end

  def fetch_apply_type(url, session_id:)
    headers = session_id.present? ? { 'Cookie' => "sessionid=#{session_id}" } : {}
    html    = @client.get(url, headers:)&.body
    return nil if html.blank?

    doc = Nokogiri::HTML(html)
    if (link = doc.at_css('a.replied-external'))
      { type: 'external', external_url: link['href'] }
    elsif doc.at_css('a#reply-btn-id')
      { type: 'internal', external_url: nil }
    end
  end

  def fetch_listing(page:)
    initialize_session
    check_termination!

    count = (page - 1) * (@items_per_page || 40)
    body  = @client.post_xhr(XHR_URL, URI.encode_www_form(count:), xhr_headers)
    return if body.blank?

    begin
      data = JSON.parse(body)
    rescue JSON::ParserError
      raise ApplyMate::Client::Base::DeadProxyError, 'non-JSON response (proxy blocked)'
    end

    nodes = Nokogiri::HTML(data['html'].to_s).css('li.l-vacancy')
    return if nodes.empty? || data['last'] == true

    @items_per_page ||= data['num']
    nodes.map { |el| extract_job_data(el) }.compact
  end

  private

  def initialize_session
    response   = @client.get(VACANCIES_URL)
    csrf_match = response&.headers&.[]('set-cookie').to_s.match(/csrftoken=([^;,\s]+)/)
    @csrf_token = csrf_match&.[](1)
    raise ApplyMate::Client::Base::DeadProxyError, 'could not extract CSRF token (proxy blocked)' if @csrf_token.blank?
  end

  def xhr_headers
    {
      'X-Requested-With' => 'XMLHttpRequest',
      'X-CSRFToken'      => @csrf_token.to_s,
      'Referer'          => VACANCIES_URL,
      'Cookie'           => "csrftoken=#{@csrf_token}",
      'Content-Type'     => 'application/x-www-form-urlencoded'
    }
  end

  def extract_job_data(element)
    link_el = element.at_css('a.vt')
    title = link_el&.text&.strip
    path = link_el&.[]('href')&.split('?')&.first
    external_id = path.to_s.match(/\/vacancies\/(\d+)/)&.[](1)

    company_el = element.at_css('a.company')
    company_name = company_el&.children&.select(&:text?)&.map(&:text)&.join&.squish

    ApplyMate::Operation::Struct.new(
      source_id:        @source.id,
      title:,
      url:              full_url(path),
      description:      sanitize_html(element.at_css('.sh-info')&.inner_html, compact: true),
      company_name:,
      company_icon_url: element.at_css('a.company img.f-i')&.[]('src'),
      external_id:
    )
  end
end
