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
    client     = ApplyMate::Client::AsyncHttp.new(timeout: 30)
    session_id = apply.source_profile.session_id

    cookie_parts = []
    cookie_parts << "sessionid=#{session_id}" if session_id.present?
    cookie_parts << apply.cookies if apply.cookies.present?

    headers = { 'Referer' => apply.vacancy.url }
    headers['Cookie'] = cookie_parts.join('; ') if cookie_parts.any?

    response = client.post_multipart(apply.action, payload: handler.build_payload(apply), headers:)

    if response.success?
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
end
