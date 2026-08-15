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

  # Embed scripts and DOM markers left by ATS widgets on employer-hosted pages.
  HTML_RULES = {
    'greenhouse' => [ /boards\.greenhouse\.io\/embed/i, /grnhse/i ],
    'lever'      => [ /lever-jobs-embed/i, /jobs\.lever\.co\/embed/i, /class="lever-/i ],
    'workable'   => [ /workable\.com\/assets\/embed/i, /whr\.js/i, /whr-embed/i ],
    'recruitee'  => [ /\.recruitee\.com\/(embed|widget)/i, /rtee-embed/i ]
  }.freeze

  def self.call(url:, html: nil)
    by_host(url) || by_html(html)
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
