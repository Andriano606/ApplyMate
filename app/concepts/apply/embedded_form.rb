# frozen_string_literal: true

# Locates the real application form when an employer page only embeds it.
#
# ATS widgets (Ashby, Greenhouse, Lever, Workable, Recruitee) render their form
# inside a cross-origin iframe. The parent document then contains zero fields,
# and neither snapshot_fields nor page_digest can look inside — JS from the
# parent origin has no access. Following the iframe to a normal top-level
# document keeps the whole pipeline (snapshot → map → fill → submit) working
# without cross-frame plumbing.
#
# Some embed URLs only render inside their embed context (Ashby's ?embed=js
# yields an empty page when opened directly), so known systems get a rewrite
# rule to their standalone form URL.
module Apply::EmbeddedForm
  # Iframes that never contain an application form — consent banners, analytics,
  # ad pixels, chat widgets, video players.
  NOISE_HOSTS = /
    usercentrics|cookiebot|onetrust|consent|doubleclick|googletagmanager|
    google\.com|googleadservices|facebook|linkedin\.com\/px|hotjar|intercom|
    youtube|vimeo|recaptcha|hcaptcha|drift|zendesk
  /xi.freeze

  # Hosts worth following even when the parent page has fields of its own.
  ATS_HOSTS = /jobs\.ashbyhq\.com|greenhouse\.io|lever\.co|workable\.com|recruitee\.com|smartrecruiters\.com|teamtailor\.com|breezy\.hr/i.freeze

  # Returns the URL of the standalone application form, or nil when the page
  # embeds nothing usable.
  def self.locate(iframe_srcs)
    candidate = Array(iframe_srcs).map(&:to_s).find { |src| form_candidate?(src) }
    return nil if candidate.blank?

    normalize(candidate)
  end

  def self.form_candidate?(src)
    return false if src.blank? || !src.start_with?('http')
    return false if src.match?(NOISE_HOSTS)

    true
  end

  # Rewrites embed-only URLs to the standalone form page.
  def self.normalize(url)
    uri = URI.parse(url)
    return url unless uri.host.to_s.match?(/(\A|\.)jobs\.ashbyhq\.com\z/i)

    # https://jobs.ashbyhq.com/{org}/{job_id}?embed=js → …/{job_id}/application
    match = uri.path.match(%r{\A/([^/]+)/([^/]+?)(?:/application)?/?\z})
    return url if match.nil?

    "https://jobs.ashbyhq.com/#{match[1]}/#{match[2]}/application"
  rescue URI::InvalidURIError
    url
  end
end
