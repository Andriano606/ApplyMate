# frozen_string_literal: true

# Greenhouse job boards. The public Job Board API describes every application
# field including custom questions, so fields come from JSON — no browser, no
# AI mapping. Submit posts multipart to the board's application endpoint.
class Apply::ExternalAts::Greenhouse < Apply::ExternalAts::Base
  API_BASE = 'https://boards-api.greenhouse.io/v1/boards'

  # Standard Greenhouse field names → canonical roles.
  ROLE_MAP = {
    'first_name'   => 'first_name',
    'last_name'    => 'last_name',
    'email'        => 'email',
    'phone'        => 'phone',
    'resume'       => 'cv_file',
    'cover_letter' => 'cover_letter',
    'location'     => 'city'
  }.freeze

  def fetch_fields(apply:)
    board, job_id = parse_url(apply.resolved_url.presence || apply.vacancy.external_url)
    payload       = get_json("#{API_BASE}/#{board}/jobs/#{job_id}?questions=true")
    questions     = payload['questions']
    raise AdapterError, 'no questions in Greenhouse payload' if questions.blank?

    position = -1
    questions.flat_map do |question|
      Array(question['fields']).map do |field|
        build_field(question, field, position += 1)
      end
    end
  end

  def submit(apply:, handler:)
    board, job_id = parse_url(apply.resolved_url.presence || apply.vacancy.external_url)
    post_multipart!(
      "https://boards.greenhouse.io/#{board}/jobs/#{job_id}",
      payload: handler.build_payload(apply),
      headers: { 'Referer' => apply.resolved_url.to_s }
    )
  end

  private

  # Accepts boards.greenhouse.io/{board}/jobs/{id}, job-boards.greenhouse.io
  # and embed URLs with for={board}&token={id}.
  def parse_url(url)
    uri    = URI.parse(url.to_s)
    params = Rack::Utils.parse_query(uri.query.to_s)
    return [ params['for'], params['token'] ] if params['for'].present? && params['token'].present?

    match = uri.path.match(%r{\A/([^/]+)/jobs/(\d+)})
    raise AdapterError, "unrecognized Greenhouse URL: #{url}" if match.nil?

    [ match[1], match[2] ]
  rescue URI::InvalidURIError
    raise AdapterError, "invalid Greenhouse URL: #{url}"
  end

  def build_field(question, field, position)
    name = field['name'].to_s
    base = name.sub(/\Ajob_application\[/, '').sub(/\].*\z/, '').sub(/\[\]\z/, '')

    ir_field(
      name:     name,
      role:     ROLE_MAP[base] || role_for_type(field),
      tag:      field['type'] == 'textarea' ? 'textarea' : 'input',
      type:     ir_type(field),
      label:    question['label'].to_s,
      required: question['required'] == true,
      options:  ir_options(field),
      position: position
    )
  end

  def role_for_type(field)
    field['type'] == 'input_file' ? 'cv_file' : 'custom_question'
  end

  def ir_type(field)
    case field['type']
    when 'input_file' then 'file'
    when 'textarea' then 'textarea'
    when 'multi_value_single_select', 'multi_value_multi_select' then 'select'
    else 'text'
    end
  end

  def ir_options(field)
    Array(field['values']).map { |v| { 'label' => v['label'].to_s, 'value' => v['value'].to_s } }.presence
  end
end
