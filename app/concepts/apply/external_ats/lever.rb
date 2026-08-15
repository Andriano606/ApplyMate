# frozen_string_literal: true

# Lever postings. The public postings API confirms the vacancy exists but does
# not describe the form — Lever application forms are standardized, so the
# field set is a known constant. Submit posts multipart to the posting's
# /apply endpoint.
class Apply::ExternalAts::Lever < Apply::ExternalAts::Base
  API_BASE = 'https://api.lever.co/v0/postings'

  def fetch_fields(apply:)
    company, posting_id = parse_url(apply.resolved_url.presence || apply.vacancy.external_url)
    posting = get_json("#{API_BASE}/#{company}/#{posting_id}?mode=json")
    raise AdapterError, 'Lever posting has no apply URL' if posting['applyUrl'].blank? && posting['id'].blank?

    standard_fields
  end

  def submit(apply:, handler:)
    company, posting_id = parse_url(apply.resolved_url.presence || apply.vacancy.external_url)
    post_multipart!(
      "https://jobs.lever.co/#{company}/#{posting_id}/apply",
      payload: handler.build_payload(apply),
      headers: { 'Referer' => "https://jobs.lever.co/#{company}/#{posting_id}/apply" }
    )
  end

  private

  def parse_url(url)
    match = URI.parse(url.to_s).path.match(%r{\A/([^/]+)/([0-9a-f-]{36})}i)
    raise AdapterError, "unrecognized Lever URL: #{url}" if match.nil?

    [ match[1], match[2] ]
  rescue URI::InvalidURIError
    raise AdapterError, "invalid Lever URL: #{url}"
  end

  def standard_fields
    [
      ir_field(name: 'name',           role: 'full_name',    label: 'Full name', required: true, position: 0),
      ir_field(name: 'email',          role: 'email',        label: 'Email', type: 'email', required: true, position: 1),
      ir_field(name: 'phone',          role: 'phone',        label: 'Phone', type: 'tel', position: 2),
      ir_field(name: 'org',            role: 'custom_question', label: 'Current company', position: 3),
      ir_field(name: 'urls[LinkedIn]', role: 'linkedin',     label: 'LinkedIn URL', position: 4),
      ir_field(name: 'comments',       role: 'cover_letter', label: 'Additional information', tag: 'textarea', type: 'textarea', position: 5),
      ir_field(name: 'resume',         role: 'cv_file',      label: 'Resume', type: 'file', required: true, position: 6)
    ]
  end
end
