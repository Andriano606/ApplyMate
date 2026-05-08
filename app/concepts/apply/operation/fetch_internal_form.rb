# frozen_string_literal: true

class Apply::Operation::FetchInternalForm < Apply::Operation::Base
  include Apply::Operation::FormExtractor

  def start_status
    :fetching_form
  end

  def error_status
    :failed_fetching_form
  end

  private

  def run!(apply:, **)
    scraper    = apply.vacancy.source.build_scraper
    session_id = apply.source_profile&.session_id
    url        = apply.vacancy.url

    headers  = session_id.present? ? { 'Cookie' => "sessionid=#{session_id}" } : {}
    response = ApplyMate::Client::Http.new.get(url, headers:, follow_redirects: true)
    raise 'Failed to fetch vacancy page' if response.nil? || response.body.blank?

    cookies   = extract_cookies(response.headers)
    doc       = Nokogiri::HTML(response.body)
    form_data = extract_form_data(doc, url, cookies, selector: scraper.form_selector)

    apply.update!(form_data: form_data)
  end
end
