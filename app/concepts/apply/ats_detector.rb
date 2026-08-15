# frozen_string_literal: true

# Detects which ATS (applicant tracking system) serves a page. Detection order:
# final-URL host → embed scripts in the HTML → DOM fingerprints. Returns a
# String key ('greenhouse', 'lever', …) or nil for self-hosted forms. A detected
# ATS without an adapter still gets recorded — the pipeline just proceeds via
# the browser path.
module Apply::AtsDetector
  HOST_RULES = {
    'greenhouse'      => [ /(\A|\.)boards\.greenhouse\.io\z/, /(\A|\.)job-boards\.greenhouse\.io\z/ ],
    'lever'           => [ /(\A|\.)jobs\.lever\.co\z/ ],
    'workable'        => [ /(\A|\.)apply\.workable\.com\z/, /\.workable\.com\z/ ],
    'recruitee'       => [ /\.recruitee\.com\z/ ],
    'smartrecruiters' => [ /(\A|\.)jobs\.smartrecruiters\.com\z/, /(\A|\.)careers\.smartrecruiters\.com\z/ ],
    'ashby'           => [ /(\A|\.)jobs\.ashbyhq\.com\z/ ],
    'teamtailor'      => [ /\.teamtailor\.com\z/ ],
    'bamboohr'        => [ /\.bamboohr\.com\z/ ],
    'breezy'          => [ /\.breezy\.hr\z/ ],
    'join'            => [ /(\A|\.)join\.com\z/ ],
    'workday'         => [ /\.myworkdayjobs\.com\z/ ]
  }.freeze

  # Query parameters ATS widgets append to the employer's own apply page — the
  # only marker available before the embed iframe loads (e.g. Preply's
  # preply.com/en/careers/apply?ashby_jid=...).
  PARAM_RULES = {
    'ashby_jid' => 'ashby',
    'gh_jid'    => 'greenhouse',
    'gh_src'    => 'greenhouse',
    'lever_jid' => 'lever'
  }.freeze

  # Embed scripts and DOM markers left by ATS widgets on employer-hosted pages.
  HTML_RULES = {
    'greenhouse' => [ /boards\.greenhouse\.io\/embed/i, /grnhse/i ],
    'lever'      => [ /lever-jobs-embed/i, /jobs\.lever\.co\/embed/i, /class="lever-/i ],
    'workable'   => [ /workable\.com\/assets\/embed/i, /whr\.js/i, /whr-embed/i ],
    'recruitee'  => [ /\.recruitee\.com\/(embed|widget)/i, /rtee-embed/i ],
    'ashby'      => [ /jobs\.ashbyhq\.com/i, /ashby_embed/i ]
  }.freeze

  def self.call(url:, html: nil)
    by_host(url) || by_param(url) || by_html(html)
  end

  def self.by_param(url)
    query = URI.parse(url.to_s).query
    return nil if query.blank?

    params = Rack::Utils.parse_query(query)
    PARAM_RULES.each { |param, ats| return ats if params[param].present? }
    nil
  rescue URI::InvalidURIError
    nil
  end

  def self.by_host(url)
    host = URI.parse(url.to_s).host.to_s.downcase.delete_prefix('www.')
    return nil if host.blank?

    HOST_RULES.each do |ats, patterns|
      return ats if patterns.any? { |pattern| host.match?(pattern) }
    end
    nil
  rescue URI::InvalidURIError
    nil
  end

  def self.by_html(html)
    return nil if html.blank?

    HTML_RULES.each do |ats, patterns|
      return ats if patterns.any? { |pattern| html.match?(pattern) }
    end
    nil
  end
end
