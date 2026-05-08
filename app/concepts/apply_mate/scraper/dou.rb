# frozen_string_literal: true

class ApplyMate::Scraper::Dou < ApplyMate::Scraper::Base
  VACANCIES_URL = 'https://jobs.dou.ua/vacancies/'
  XHR_URL       = 'https://jobs.dou.ua/vacancies/xhr-load/'

  def initialize(source = Source.find_by(name: 'Dou'), client = ApplyMate::Client::Http.new)
    @source = source
    @client = client
  end

  def fetch_details(url)
    html = @client.fetch_body(url)
    return nil if html.blank?

    doc  = Nokogiri::HTML(html)
    node = doc.at_css('div.l-vacancy')
    return nil if node.nil?

    sanitize_html(node.inner_html, compact: true)
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

  def fetch_listing
    initialize_session
    all_jobs = []
    count = 0

    loop do
      if Thread.main[:solid_queue_terminating]
        Rails.logger.info 'Termination signal received. Saving collected jobs and exiting...'
        break
      end

      Rails.logger.info "Scraping DOU vacancies, offset: #{count}"

      body = @client.post_xhr(XHR_URL, URI.encode_www_form(count: count), xhr_headers)
      break if body.blank?

      data = JSON.parse(body)
      nodes = Nokogiri::HTML(data['html'].to_s).css('li.l-vacancy')
      break if nodes.empty?

      all_jobs.concat(nodes.map { |el| extract_job_data(el) }.compact)

      break if data['last'] == true

      count += (data['num'] || nodes.size)
      sleep(rand(2..5))
    end

    all_jobs
  end

  private

  def initialize_session
    response = @client.get(VACANCIES_URL)
    csrf_match = response&.headers&.[]('set-cookie').to_s.match(/csrftoken=([^;,\s]+)/)
    @csrf_token = csrf_match&.[](1)
    Rails.logger.warn '[DOU] Could not extract CSRF token from session' if @csrf_token.blank?
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
    path = link_el&.[]('href')
    external_id = path.to_s.match(/\/vacancies\/(\d+)/)&.[](1)

    company_el = element.at_css('a.company')
    company_name = company_el&.children&.select(&:text?)&.map(&:text)&.join&.strip

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
