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
  # The job board SPA's submit mutations (Apollo HttpLink: `?op=<operationName>`, JSON POST): one form, or the
  # application form plus survey forms. Field values were stored earlier by ApiSetFormValue / file-upload ops.
  SUBMIT_OPS = %w[ApiSubmitSingleApplicationFormAction ApiSubmitMultipleFormsAction].freeze
  # The confirmation view Ashby renders inside #form[role=tabpanel] after a FormSubmitSuccess (role=status: a
  # "Success" heading plus the org's own message, applicationSubmittedSuccessMessage, or the default "Your
  # application was successfully submitted..."). The URL never changes.
  SUCCESS_SELECTORS = [ '.ashby-application-form-success-container' ].freeze
  # "We couldn't submit your application": the submit failed, or the candidate is blocked (which still answers
  # FormSubmitSuccess, with messages.blockMessageForCandidateHtml).
  FAILURE_SELECTORS = %w[.ashby-application-form-failure-container .ashby-application-form-blocked-application-container].freeze
  # The default copy and common custom copy (Preply: "Application received! Thank you for taking the first step...").
  # Never a bare "success": the copy is the org's, the selectors above are the copy-independent signal.
  SUCCESS_TEXTS = [
    /application (was |has been )?(successfully )?submitted/i, /application (was |has been )?received/i,
    /thank(s| you) for (applying|your application)/i
  ].freeze

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

    # The submit mutation only (NetTracker watches it): never ApiSetFormValue, autofill or file-upload ops.
    def submit_url
      %r{\A#{Regexp.escape(origin)}/api/non-user-graphql\?op=(?:#{SUBMIT_OPS.join('|')})(?:&|\z)}
    end

    # The submit mutation's JSON says the application was accepted: no GraphQL errors, the application form result
    # (any alias: data.submitApplicationFormAction / data.submitMultipleFormsAction) and every survey form result
    # are FormSubmitSuccess, and no block message. A validation re-render answers HTTP 200 with FormRender.
    def submit_accepted?(json)
      result = json['data'].is_a?(Hash) && json['data'].values.find { |value| value.is_a?(Hash) && value.key?('applicationFormResult') }
      return false if json['errors'].present? || !result

      [ result['applicationFormResult'], *Array(result['surveyFormResults']) ].all? do |form|
        form.is_a?(Hash) && form['__typename'] == 'FormSubmitSuccess'
      end && result.dig('messages', 'blockMessageForCandidateHtml').blank?
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

  # Two of: the confirmation view (success_dom), the submit mutation's FormSubmitSuccess (submit_request), the
  # confirmation copy (success_text). The first two are copy-independent; a failure view vetoes.
  def success_evidence
    {
      texts: SUCCESS_TEXTS, url_patterns: [], selectors: SUCCESS_SELECTORS, failure_selectors: FAILURE_SELECTORS,
      submit_request: { url: self.class.submit_url, body_ok: ->(json) { self.class.submit_accepted?(json) } },
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
