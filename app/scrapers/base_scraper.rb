# frozen_string_literal: true

class BaseScraper
  def initialize(source, client)
    @source = source
    @client = client
  end

  def perform
    all_jobs = []
    page = 1

    loop do
      # Формуємо URL для поточної сторінки
      # Якщо у @source.job_list_url вже є параметри, використовуємо &page=, інакше ?page=
      separator = @source.job_list_url.include?('?') ? '&' : '?'
      current_url = "#{@source.job_list_url}#{separator}page=#{page}"

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

      page += 1
    end

    all_jobs
  end

  private

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
      company_icon_url: image_valid?(company_icon_url) ? company_icon_url : nil,
      external_id:
    )
  end

  def image_valid?(url)
    return false if url.blank?

    uri = URI.parse(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    http.open_timeout = 2 # Не чекаємо довго
    http.read_timeout = 2

    # Використовуємо HEAD замість GET
    response = http.request_head(uri.request_uri)

    # Перевіряємо, чи статус 200 OK і чи це дійсно зображення
    response.code == '200' && response['Content-Type']&.start_with?('image/')
  rescue StandardError => e
    Rails.logger.error "Image validation error: #{e.message}"
    false
  end

  def full_url(path)
    return nil if path.blank?
    URI.join(@source.base_url, path).to_s
  rescue StandardError
    path
  end

  def sanitize_html(html)
    return '' if html.blank?
    ActionController::Base.helpers.sanitize(html, tags: %w[p br strong ul li b]).strip
  end
end
