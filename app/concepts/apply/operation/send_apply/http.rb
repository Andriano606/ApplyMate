# frozen_string_literal: true

class Apply::Operation::SendApply::Http < Apply::Operation::Base
  stage :submit

  LOGIN_PATH = %r{/login|/signin|/auth}i

  private

  # The claim is taken after everything that can fail without side effects (payload, CV download) and right
  # before the POST. From then on every outcome but a 2xx or a success redirect lands in submit_unverified
  # (claim rule), except a redirect to the login page: deterministic proof the board never accepted the POST,
  # so the claim is released and the user is asked to refresh the session.
  def run!(apply:, handler:, ctx:, **)
    # Submit through the source's own client so a Cloudflare-protected board sees the
    # same TLS fingerprint that fetched the form (AsyncHttp would get a 403 challenge).
    client     = apply.vacancy.source.http_client(request_timeout: 30)
    session_id = apply.source_profile.session_id

    cookie_header = build_cookie_header(apply.vacancy.source.session_cookie_name, session_id, apply.cookies)

    headers = { 'Referer' => apply.vacancy.url }
    headers['Cookie'] = cookie_header if cookie_header.present?
    payload = handler.build_payload(apply)

    Apply::Operation::Engine::ClaimSubmit.call(ctx:)
    verify_response(apply, client.post_multipart(apply.action, payload:, headers:))
  end

  # 2xx or a redirect elsewhere: submitted (the Runner's Finish records completed + submitted_at).
  def verify_response(apply, response)
    halt!(:outcome_unknown, detail: 'no response') if response.nil?
    return if (200..299).cover?(response.status)
    return verify_redirect(apply, response.headers['location'].to_s) if [ 301, 302, 303 ].include?(response.status)

    halt!(:outcome_unknown, detail: "HTTP #{response.status}")
  end

  def verify_redirect(apply, location)
    halt!(:session_expired, detail: location, definitive: true) if location.match?(LOGIN_PATH)

    vacancy_path  = URI.parse(apply.vacancy.url).path.chomp('/')
    location_uri  = URI.parse(location)
    same_page_no_success = location_uri.path.chomp('/') == vacancy_path && !location_uri.query.to_s.include?('applied')
    halt!(:outcome_unknown, detail: location) if same_page_no_success
  end

  # Captured form-page cookies first, then the profile's session under the platform's
  # cookie name — so the authenticated session always wins over an anonymous captured one.
  def build_cookie_header(session_cookie_name, session_id, captured_cookies)
    jar = {}

    captured_cookies.to_s.split(/;\s*/).each do |pair|
      name, value = pair.split('=', 2)
      jar[name.strip] = value if name.present? && value.present?
    end

    jar[session_cookie_name] = session_id if session_id.present?

    jar.map { |name, value| "#{name}=#{value}" }.join('; ')
  end
end
