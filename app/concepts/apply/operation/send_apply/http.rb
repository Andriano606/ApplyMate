# frozen_string_literal: true

class Apply::Operation::SendApply::Http < Apply::Operation::Base
  def start_status
    :sending_cv
  end

  def error_status
    :failed_sending_cv
  end

  def success_status
    :completed
  end

  private

  def run!(apply:, handler:, **)
    client     = ApplyMate::Client::AsyncHttp.new(request_timeout: 30)
    session_id = apply.source_profile.session_id

    cookie_header = build_cookie_header(session_id, apply.cookies)

    headers = { 'Referer' => apply.vacancy.url }
    headers['Cookie'] = cookie_header if cookie_header.present?

    response = client.post_multipart(apply.action, payload: handler.build_payload(apply), headers:)
    raise 'Submission failed — no response from server' if response.nil?

    if (200..299).cover?(response.status)
    elsif [ 301, 302, 303 ].include?(response.status)
      location      = response.headers['location'].to_s
      vacancy_uri   = URI.parse(apply.vacancy.url).path.chomp('/')
      location_uri  = URI.parse(location)
      location_path = location_uri.path.chomp('/')
      same_page_no_success = location_path == vacancy_uri && !location_uri.query.to_s.include?('applied')

      raise "Submission rejected — redirected to: #{location}" if location.match?(%r{/login|/signin|/auth}i) || same_page_no_success
    else
      raise "HTTP #{response.status}: #{response.body[0..500]}"
    end
  end

  def build_cookie_header(session_id, captured_cookies)
    jar = {}

    captured_cookies.to_s.split(/;\s*/).each do |pair|
      name, value = pair.split('=', 2)
      jar[name.strip] = value if name.present? && value.present?
    end

    jar['sessionid'] = session_id if session_id.present?

    jar.map { |name, value| "#{name}=#{value}" }.join('; ')
  end
end
