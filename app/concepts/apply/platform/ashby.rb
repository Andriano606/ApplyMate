# frozen_string_literal: true

# Ashby job boards (design §5.3): jobs.ashbyhq.com/<slug>/<jid>, often embedded on the company site as
# iframe#ashby_embed_iframe (Preply). Almost only data: the form has a direct URL (canonical_form_url) and a public
# read-only schema (Operation::Platform::Ashby::FetchSchema). Every URL and pattern is built from `origin` (one
# place), so a spec subclass can point the adapter at FixtureSite: override `self.origin`, then call
# `declare_signals!` in its body.
class Apply::Platform::Ashby < Apply::Platform::Base
  UUID = '\h{8}-\h{4}-\h{4}-\h{4}-\h{12}'
  # Radio / checkbox ids and names carry a per-render form-instance UUID: "<instance uuid>_<question uuid>".
  # The ONE definition of that rule: a regex source valid in Ruby and JS, used by #field_key (INSTANCE_PREFIX) and
  # passed to probe/readiness.js through #readiness (key_prefix).
  INSTANCE_PREFIX_SOURCE = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}_'
  INSTANCE_PREFIX = /\A(?:#{INSTANCE_PREFIX_SOURCE})/i
  FIELD_PATH_ATTR = 'data-field-path'
  SYSTEM_FIELDS = {
    '_systemfield_name' => 'full_name', '_systemfield_email' => 'email', '_systemfield_resume' => 'cv',
    '_systemfield_phone' => 'phone'
  }.freeze

  class << self
    def origin
      'https://jobs.ashbyhq.com'
    end

    # Origin without the scheme ("jobs.ashbyhq.com"): URLs in evidence are matched on it.
    def authority
      origin.sub(%r{\A[a-z]+://}i, '')
    end

    def job_url
      %r{#{Regexp.escape(authority)}/(?<slug>[^/?#]+)/(?<jid>#{UUID})}
    end

    def graphql_url
      %r{\A#{Regexp.escape(origin)}/api/non-user-graphql}
    end

    def declare_signals!
      signal :host, /\A#{Regexp.escape(URI.parse(origin).host)}\z/, weight: 0.7
      signal :url, job_url, weight: 0.95, captures: %i[slug jid]
      signal :frame_src, job_url, weight: 0.95, captures: %i[slug jid]
      signal :script_src, %r{#{Regexp.escape(authority)}/(?<slug>[^/?#]+)/embed}, weight: 0.85, captures: %i[slug]
      signal :query_param, 'ashby_jid', weight: 0.6, captures: %i[jid]
      signal :dom, '.ashby-application-form-field-entry', weight: 0.9
    end
  end

  declare_signals!
  required_captures :slug, :jid
  throttle 10.minutes, key: ->(ctx) { "ashby:#{ctx.match.captures['slug']}" }

  def canonical_form_url
    "#{self.class.origin}/#{slug}/#{jid}/application"
  end

  def fetch_schema
    Apply::Operation::Platform::Ashby::FetchSchema.call(slug:, jid:, http: ctx.http, origin: self.class.origin).model
  rescue Apply::Platform::SchemaUnavailable => e
    ctx.trace(:schema_unavailable, platform: self.class.key, detail: e.message)
    nil
  end

  def apply_key
    "ashby:#{slug}:#{jid}"
  end

  # The "autofill from resume" pane: uploading there overwrites the answers.
  def excluded_regions
    [ '.ashby-application-form-autofill-input-root' ]
  end

  def form_root_selector
    '#form[role="tabpanel"]'
  end

  def field_key(raw)
    path = raw.attr(FIELD_PATH_ATTR).presence || raw.attr('name').presence
    return super if path.nil?

    "#{self.class.key}:#{path.sub(INSTANCE_PREFIX, '')}"
  end

  # Ashby's built-in application fields carry fixed keys ("_systemfield_email").
  def semantic_for(field)
    SYSTEM_FIELDS[field.id.delete_prefix("#{self.class.key}:")]
  end

  # Files first: the resume upload re-renders parts of the form.
  def fill_order(fields)
    fields.partition(&:file?).flatten
  end

  # Schema keys ATTACHED inside the form root, any visibility (clipped file input, opacity-0 radios count).
  def readiness
    return if ctx.schema.blank?

    Readiness.schema_keys(keys: ctx.schema_keys, attr: FIELD_PATH_ATTR, root: form_root_selector,
                          key_prefix: INSTANCE_PREFIX_SOURCE)
  end

  # Until the submit mutation is measured, success needs TWO independent signals.
  def success_evidence
    {
      texts: [ /application (was )?(successfully )?submitted/i, /thank(s| you) for applying/i ],
      url_patterns: [],
      submit_request: { url: self.class.graphql_url,
                        body_ok: ->(json) { json['errors'].blank? && json['data'].present? } },
      min_signals: 2
    }
  end

  private

  def slug
    match.captures.fetch('slug')
  end

  def jid
    match.captures.fetch('jid')
  end
end
