# frozen_string_literal: true

class DjinniScraper < BaseScraper
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

      separator   = @source.job_list_url.include?('?') ? '&' : '?'
      current_url = "#{@source.job_list_url}#{separator}page=#{page}"

      Rails.logger.info "Scraping page #{page}: #{current_url}"

      doc = Nokogiri::HTML(@client.fetch_response(current_url).body)

      nodes = doc.css('.job-list-item, .job-item')
      break if nodes.empty?

      all_jobs.concat(nodes.map { |el| extract_job_data(el) })

      page += 1
    end

    all_jobs
  end

  def fetch_details(url)
    doc = Nokogiri::HTML(@client.fetch_response(url).body)

    sections = []

    skills = parse_section(doc, 'Необхідний досвід з навичками', 'span.fw-bold')
    sections << format_section('Необхідний досвід з навичками', skills) if skills.any?

    languages = parse_section(doc, 'Вимоги до володіння мовами', 'span.fw-semibold')
    sections << format_section('Вимоги до володіння мовами', languages) if languages.any?

    sections.reject(&:blank?).join("\n\n")
  end

  def fetch_form_data(url, session_id: nil)
    response = session_client(session_id).fetch_response(url)
    doc      = Nokogiri::HTML(response.body)
    form     = doc.at_css('form#apply_form')
    return nil unless form

    csrf_match = response.headers['set-cookie'].to_s.match(/csrftoken=([^;,\s]+)/)

    data = {
      action:  full_url(form['action']) || url,
      method:  form['method'] || 'post',
      enctype: form['enctype'],
      cookies: csrf_match ? "csrftoken=#{csrf_match[1]}" : nil,
      inputs:  []
    }

    radio_groups = {}

    form.css('input, textarea, select, button').each do |el|
      next if el.name == 'button'
      next if el['type'] == 'submit'
      next if el['name'].blank?

      if el['type'] == 'radio'
        name         = el['name']
        option_label = form.at_css("label[for='#{el["id"]}']")&.text&.strip

        if radio_groups.key?(name)
          data[:inputs][radio_groups[name]][:options] << { label: option_label, value: el['value'] }
        else
          entry = {
            id:          nil,
            tag:         'input',
            type:        'radio',
            name:        name,
            label:       find_radio_question_label(el, form),
            value:       nil,
            placeholder: nil,
            options:     [ { label: option_label, value: el['value'] } ]
          }
          radio_groups[name] = data[:inputs].size
          data[:inputs] << entry
        end
        next
      end

      input_data = {
        id:          el['id'],
        tag:         el.name,
        type:        el['type'],
        name:        el['name'],
        value:       el['value'],
        placeholder: el['placeholder']
      }
      input_data[:value] = el.text.strip if el.name == 'textarea'
      input_data[:label] = find_input_label(el, form).presence

      data[:inputs] << input_data
    end

    ApplyMate::Operation::Struct.new(data)
  end

  def fetch_applyble(url, session_id:)
    response = session_client(session_id).fetch_response(url)
    doc      = Nokogiri::HTML(response.body)

    button = doc.at_css('button.js-inbox-toggle-reply-form')
    unless button
      button = doc.xpath("//button[contains(translate(text(), 'ВІДГУКНУТИСЯ', 'відгукнутися'), 'відгукнутися')]").first
    end

    !!(button && !button['disabled'])
  end

  private

  def session_client(session_id)
    headers = session_id.present? ? { 'Cookie' => "sessionid=#{session_id}" } : {}
    HttpClient.new(headers:)
  end

  def find_radio_question_label(el, form)
    container = el.parent
    until container.nil? || container == form
      container.css('> label').each do |label|
        for_id = label['for']
        next if for_id.present? && form.at_css("input[type='radio'][id='#{for_id}']")
        text = label.text.strip
        return text if text.present?
      end
      container = container.parent
    end
    nil
  end

  def find_input_label(el, form)
    if el['id'].present?
      label = form.at_css("label[for='#{el["id"]}']")&.text&.strip
      return label if label.present?
    end

    container = el.parent
    while container && container != form
      local_label = container.at_css('label')
      if local_label && (local_label['for'].blank? || local_label['for'] == el['id'])
        return local_label.text.strip
      end

      prev = container.previous_element
      while prev
        return prev.text.strip if prev.name == 'label'
        sibling_label = prev.at_css('label')
        return sibling_label.text.strip if sibling_label
        prev = prev.previous_element
      end

      container = container.parent
    end
    nil
  end

  def parse_section(doc, header_text, name_selector)
    header = doc.at_xpath("//h2[contains(., '#{header_text}')] | //h3[contains(., '#{header_text}')]")
    return {} unless header

    data    = {}
    current = header.next_element
    while current && !current.name.match?(/^h[1-6]$/)
      table_rows = current.name == 'table' ? current.css('tr') : current.css('table tr')
      table_rows.each do |row|
        name  = row.at_css(name_selector)&.text&.strip
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
    title       = element.at_css('h2.job-item__position')&.text&.strip
    url         = element.at_css(".job-list-item__link, .job_item__header-link, a[href*='/jobs/']")&.[]('href')
    external_id = url.to_s.scan(/\d+/).first
    description_node = element.at_css('.js-original-text') || element.at_css("#job-description-#{external_id}")
    description      = sanitize_html(description_node&.inner_html)
    company_name     = element.at_css('.small.text-gray-800, .job-list-item__company-name')&.text&.strip
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

  def full_url(path)
    return nil if path.blank?
    URI.join(@source.base_url, path).to_s
  rescue StandardError
    path
  end

  def sanitize_html(html)
    return '' if html.blank?
    Html2Text.convert(html)
  end
end
