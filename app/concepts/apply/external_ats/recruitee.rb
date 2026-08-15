# frozen_string_literal: true

# Recruitee career sites. The public offers API returns the offer (and its
# open questions); the candidate endpoint accepts a multipart POST. Standard
# candidate fields are fixed; open questions map to custom_question.
class Apply::ExternalAts::Recruitee < Apply::ExternalAts::Base
  def fetch_fields(apply:)
    company, slug = parse_url(apply.resolved_url.presence || apply.vacancy.external_url)
    payload = get_json("https://#{company}.recruitee.com/api/offers/#{slug}")
    offer   = payload['offer'] || payload
    raise AdapterError, 'no offer in Recruitee payload' if offer['title'].blank? && offer['slug'].blank?

    standard_fields + question_fields(offer)
  end

  def submit(apply:, handler:)
    company, slug = parse_url(apply.resolved_url.presence || apply.vacancy.external_url)
    post_multipart!(
      "https://#{company}.recruitee.com/api/offers/#{slug}/candidates",
      payload: handler.build_payload(apply),
      headers: { 'Referer' => apply.resolved_url.to_s }
    )
  end

  private

  def parse_url(url)
    uri   = URI.parse(url.to_s)
    match = uri.host.to_s.match(/\A([^.]+)\.recruitee\.com\z/)
    slug  = uri.path.match(%r{/o/([^/]+)})
    raise AdapterError, "unrecognized Recruitee URL: #{url}" if match.nil? || slug.nil?

    [ match[1], slug[1] ]
  rescue URI::InvalidURIError
    raise AdapterError, "invalid Recruitee URL: #{url}"
  end

  def standard_fields
    [
      ir_field(name: 'candidate[name]',         role: 'full_name',    label: 'Full name', required: true, position: 0),
      ir_field(name: 'candidate[email]',        role: 'email',        label: 'Email', type: 'email', required: true, position: 1),
      ir_field(name: 'candidate[phone]',        role: 'phone',        label: 'Phone', type: 'tel', position: 2),
      ir_field(name: 'candidate[cover_letter]', role: 'cover_letter', label: 'Cover letter', tag: 'textarea', type: 'textarea', position: 3),
      ir_field(name: 'candidate[cv]',           role: 'cv_file',      label: 'CV', type: 'file', required: true, position: 4)
    ]
  end

  def question_fields(offer)
    Array(offer['open_questions']).each_with_index.map do |question, index|
      ir_field(
        name:     "candidate[open_question_answers_attributes][#{index}][content]",
        role:     'custom_question',
        label:    (question['body'].presence || question['title']).to_s,
        tag:      'textarea',
        type:     'textarea',
        required: question['required'] == true,
        position: 5 + index
      )
    end
  end
end
