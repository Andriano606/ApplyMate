# frozen_string_literal: true

# Workable hosted apply pages. The public form API returns the exact field
# structure (including custom questions); submit posts multipart to the public
# apply endpoint of the same API.
class Apply::ExternalAts::Workable < Apply::ExternalAts::Base
  ROLE_MAP = {
    'firstname'      => 'first_name',
    'lastname'       => 'last_name',
    'name'           => 'full_name',
    'email'          => 'email',
    'phone'          => 'phone',
    'resume'         => 'cv_file',
    'cover_letter'   => 'cover_letter',
    'address'        => 'city',
    'linkedin'       => 'linkedin',
    'github'         => 'github',
    'portfolio'      => 'portfolio',
    'website'        => 'website'
  }.freeze

  def fetch_fields(apply:)
    company, shortcode = parse_url(apply.resolved_url.presence || apply.vacancy.external_url)
    payload = get_json("https://apply.workable.com/api/v1/accounts/#{company}/jobs/#{shortcode}/form")
    fields  = Array(payload['fields']) + Array(payload['questions'])
    raise AdapterError, 'no fields in Workable payload' if fields.empty?

    fields.each_with_index.map { |field, index| build_field(field, index) }
  end

  def submit(apply:, handler:)
    company, shortcode = parse_url(apply.resolved_url.presence || apply.vacancy.external_url)
    post_multipart!(
      "https://apply.workable.com/api/v1/accounts/#{company}/jobs/#{shortcode}/apply",
      payload: handler.build_payload(apply),
      headers: { 'Referer' => apply.resolved_url.to_s }
    )
  end

  private

  def parse_url(url)
    match = URI.parse(url.to_s).path.match(%r{\A/([^/]+)/j/([^/]+)})
    raise AdapterError, "unrecognized Workable URL: #{url}" if match.nil?

    [ match[1], match[2] ]
  rescue URI::InvalidURIError
    raise AdapterError, "invalid Workable URL: #{url}"
  end

  def build_field(field, position)
    key  = (field['key'].presence || field['id']).to_s
    type = field['type'].to_s

    ir_field(
      name:     key,
      role:     ROLE_MAP[key] || (type == 'file' ? 'cv_file' : 'custom_question'),
      tag:      type == 'free_text' ? 'textarea' : 'input',
      type:     ir_type(type),
      label:    (field['label'].presence || field['body']).to_s,
      required: field['required'] == true,
      options:  ir_options(field),
      position: position
    )
  end

  def ir_type(type)
    case type
    when 'file' then 'file'
    when 'free_text' then 'textarea'
    when 'multiple_choice', 'dropdown' then 'select'
    when 'boolean' then 'checkbox'
    else 'text'
    end
  end

  def ir_options(field)
    Array(field['options']).map { |o| { 'label' => o['body'].to_s, 'value' => (o['id'].presence || o['body']).to_s } }.presence
  end
end
