# frozen_string_literal: true

require 'faraday/multipart'

class Apply::Operation::SendApply < ApplyMate::Operation::Base
  def perform!(apply:, **)
    skip_authorize
    self.model = apply

    return if apply.error.present?

    return if apply.filled_form_data.blank? || apply.form_data.blank?

    apply.update!(status: :sending_cv)
    Apply::TurboHandler::StatusUpdate.broadcast(apply.vacancy)

    response = send_request(apply)

    if response.success?
      apply.update!(status: :completed)
    elsif [ 301, 302, 303 ].include?(response.status)
      location = response.headers['location'].to_s
      vacancy_uri = URI.parse(apply.vacancy.url).path.chomp('/')
      location_uri = URI.parse(location)
      location_path = location_uri.path.chomp('/')
      same_page_no_success = location_path == vacancy_uri && !location_uri.query.to_s.include?('applied')

      if location.match?(%r{/login|/signin|/auth}i) || same_page_no_success
        apply.update!(status: :failed_cv_sending, error: "Submission rejected — redirected to: #{location}")
      else
        apply.update!(status: :completed)
      end
    else
      apply.update!(status: :failed_cv_sending, error: "HTTP #{response.status}: #{response.body[0..500]}")
    end

    Apply::TurboHandler::StatusUpdate.broadcast(apply.vacancy)
  rescue StandardError => e
    apply.update!(status: :failed_cv_sending, error: e.message)
    Apply::TurboHandler::StatusUpdate.broadcast(apply.vacancy)
    raise
  end

  def self.build_connection_params(apply)
    cookie_parts = []
    cookie_parts << "sessionid=#{apply.source_profile.session_id}" if apply.source_profile&.session_id.present?
    cookie_parts << apply.form_data['cookies'] if apply.form_data['cookies'].present?

    headers = {
      'User-Agent' => 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      'Referer'    => apply.vacancy.url
    }
    headers['Cookie'] = cookie_parts.join('; ') if cookie_parts.any?

    {
      url:        apply.form_data['action'],
      method:     (apply.form_data['method'] || 'post'),
      headers:,
      payload:    extract_payload(apply.filled_form_data),
      file_input: apply.form_data['inputs']&.find { |i| i['type'] == 'file' }
    }
  end

  def self.extract_payload(filled_form_data)
    inputs = filled_form_data['inputs'] || filled_form_data[:inputs] || []
    inputs.reject { |i| i['type'] == 'file' }
          .each_with_object({}) { |i, h| h[i['name']] = i['value'].to_s }
  end

  private

  def send_request(apply)
    params = self.class.build_connection_params(apply)

    if apply.cv.attached? && params[:file_input]
      file_content = apply.cv.download
      params[:payload][params[:file_input]['name']] = Faraday::Multipart::FilePart.new(
        StringIO.new(file_content),
        apply.cv.content_type,
        apply.cv.filename.to_s
      )
    end

    connection = Faraday.new do |f|
      f.request :multipart
      f.request :url_encoded
      f.options.timeout      = 30
      f.options.open_timeout = 10
      params[:headers].each { |k, v| f.headers[k] = v }
      f.adapter Faraday.default_adapter
    end

    connection.public_send(params[:method].downcase.to_sym, params[:url], params[:payload])
  end
end
