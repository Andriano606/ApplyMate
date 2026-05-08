# frozen_string_literal: true

class ApplyMate::Scraper::Djinni < ApplyMate::Scraper::Base
  JOB_LIST_URL = 'https://djinni.co/jobs/'

  def initialize(source, client)
    @source = source
    @client = client
  end

  def fetch_listing
    all_jobs = []
    page = 1

    loop do
      if Thread.main[:solid_queue_terminating]
        Rails.logger.info 'Termination signal received. Saving collected jobs and exiting...'
        break
      end

      current_url = "#{JOB_LIST_URL}?page=#{page}"

      Rails.logger.info "Scraping page #{page}: #{current_url}"

      body = @client.fetch_body(current_url)
      doc = Nokogiri::HTML(body)

      # Шукаємо елементи вакансій
      nodes = doc.css('.job-list-item, .job-item')

      # Якщо вакансій на сторінці немає — зупиняємо цикл
      break if nodes.empty?

      page_jobs = nodes.map do |element|
        extract_job_data(element)
      end

      all_jobs.concat(page_jobs)

      # Пауза від 2 до 5 секунд після кожного успішного запиту
      sleep(rand(2..5))

      page += 1
    end

    all_jobs
  end

  def fetch_details(url)
    body = @client.fetch_body(url)
    doc = Nokogiri::HTML(body)

    sections = []

    skills = parse_section(doc, 'Необхідний досвід з навичками', 'span.fw-bold')
    sections << format_section('Необхідний досвід з навичками', skills) if skills.any?

    languages = parse_section(doc, 'Вимоги до володіння мовами', 'span.fw-semibold')
    sections << format_section('Вимоги до володіння мовами', languages) if languages.any?

    sections.reject(&:blank?).join("\n\n")
  end

  def fetch_apply_type(_url, session_id: nil)
    { type: 'internal', external_url: nil }
  end

  def form_selector
    'form#apply_form'
  end

  def fetch_applyble(url, session_id:)
    headers  = session_id.present? ? { 'Cookie' => "sessionid=#{session_id}" } : {}
    response = @client.get(url, headers:)
    return false if response.nil?

    doc    = Nokogiri::HTML(response.body)
    button = doc.at_css('button.js-inbox-toggle-reply-form')
    button ||= doc.xpath("//button[contains(translate(text(), 'ВІДГУКНУТИСЯ', 'відгукнутися'), 'відгукнутися')]").first

    !!(button && !button['disabled'])
  end

  private

  def parse_section(doc, header_text, name_selector)
    header = doc.at_xpath("//h2[contains(., '#{header_text}')] | //h3[contains(., '#{header_text}')]")
    return {} unless header

    data = {}
    current = header.next_element
    while current && !current.name.match?(/^h[1-6]$/)
      table_rows = current.name == 'table' ? current.css('tr') : current.css('table tr')
      table_rows.each do |row|
        name = row.at_css(name_selector)&.text&.strip
        value = row.css('td').last&.text&.strip
        data[name] = value if name.present? && value.present?
      end
      current = current.next_element
    end
    data
  end

  def format_section(title, data)
    lines = [ "#{title}:" ] + data.map { |name, value| "#{name} — #{value}" }
    lines.join("\n")
  end

  def extract_job_data(element)
    title = element.at_css('h2.job-item__position')&.text&.strip
    url = element.at_css('.job-list-item__link, .job_item__header-link, a[href*="/jobs/"]')&.[]('href')
    external_id = url.to_s.scan(/\d+/).first
    description_node = element.at_css('.js-original-text') || element.at_css("#job-description-#{external_id}")
    description = sanitize_html(description_node&.inner_html)
    company_name = element.at_css('.small.text-gray-800, .job-list-item__company-name')&.text&.strip
    company_icon_url = element.at_css('img.userpic-image')&.[]('src')

    ApplyMate::Operation::Struct.new(
      source_id: @source.id,
      title:,
      url: full_url(url),
      description:,
      company_name:,
      company_icon_url:,
      external_id:
    )
  end
end
