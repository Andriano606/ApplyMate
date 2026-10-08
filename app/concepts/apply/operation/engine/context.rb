# frozen_string_literal: true

# One run of one Apply, built only by Apply::Operation::Engine::StartContext.
#
#   apply       Apply - the row this run owns (reloaded by the Runner/Lifecycle when they need fresh columns)
#   attempt     Integer - applies.attempt after the start UPDATE (apply_steps rows carry it)
#   run_token   String (uuid) - the fencing token; every engine write matches on it (FencedUpdate)
#   deadline_at Time - the run's wall-clock budget (Apply::RUN_DEADLINE after start)
#   fence_flag  Concurrent::AtomicBoolean - shared with the heartbeat thread, set once the run is fenced
#   scratch     Context::Scratch - the run's mutable in-memory state (platform, match, schema, session, trace);
#               shared between copies made with #with, never persisted as a whole
#
# The members are immutable. Writes to `applies` go through #persist! (FencedUpdate); everything else the stages
# learn during the run lives in `scratch`.
Apply::Operation::Engine::Context = Data.define(:apply, :attempt, :run_token, :deadline_at, :fence_flag, :scratch)

# Reopened (not `Data.define do … end`) so methods and docs read like a normal class.
class Apply::Operation::Engine::Context
  # Longest a single browser session may live; shorter than browserd's LEASE_TTL_S = 600, so the client
  # gives up (DeadlineExceeded) before browserd reaps the lease under it.
  SCOPE_DEADLINE = 8.minutes
  # At most this many platform switches per run (generic -> ashby counts): redetection after every page change
  # cannot flip-flop between two adapters forever.
  MAX_PLATFORM_SWITCHES = 2
  # Trace entries kept in memory per run (the newest win); the Runner redacts them when it stores a step's trace.
  MAX_TRACE = 100
  # Timeout of the run's HTTP client (ctx.http: redirect walk, schema endpoints); curl's --max-time per request.
  HTTP_TIMEOUT = 15

  # session          ApplyMate::Client::Browser::Session of the open scope, or nil
  # scope            :survey | :submit | nil, scope_deadline: Time the open scope must end by
  # platform, match  the adopted Apply::Platform::* instance and its Detect::Match
  # evidence         Detect::Evidence merged over the run (http + rendered levels)
  # schema           [Apply::Field] from platform.fetch_schema (source schema_api)
  # fields, form_root, form_url  what the survey found (DiscoverFields / ReachForm)
  # trace            [{ 'at', 'event', ... }] at most MAX_TRACE
  # platform_switches, consent_clicks (per session), artifacts_count  counters with caps
  # canonical_unwrapped  platform keys whose canonical_form_url ReachForm already opened in this session (at most
  #                  one canonical navigation per platform per scope; reset with the session)
  # claim_mark       NetTracker mark taken right after the submit claim
  # http             the run's ImpersonateHttp (built once)
  # step_record      the ApplyStep row of the running step (set by the Runner; Stage::Submit attaches the
  #                  before_submit artifact to it)
  Scratch = Struct.new(:session, :scope, :scope_deadline, :platform, :match, :evidence, :schema, :fields, :form_root,
                       :form_url, :trace, :platform_switches, :claim_mark, :artifacts_count, :consent_clicks, :http,
                       :canonical_unwrapped, :step_record, keyword_init: true) do
    def self.fresh
      new(trace: [], platform_switches: 0, artifacts_count: 0, consent_clicks: 0, canonical_unwrapped: [])
    end
  end

  def initialize(scratch: nil, **members)
    super(scratch: scratch || Scratch.fresh, **members)
  end

  # Seconds left: until deadline_at, or until the open session scope's deadline when that comes first
  # (negative once passed).
  def remaining
    [ deadline_at, scratch.scope_deadline ].compact.min - Time.current
  end

  # `seconds`, never more than what is left (and never negative): timeouts inside a step.
  def clamp(seconds)
    [ seconds, remaining ].min.clamp(0, nil)
  end

  # The deadline a browser Session gets: its own budget, never past the run's deadline.
  def scope_deadline
    [ Time.current + SCOPE_DEADLINE, deadline_at ].min
  end

  def fenced?
    fence_flag.true?
  end

  def fence!
    fence_flag.make_true
  end

  def check_fence!
    raise Apply::Operation::Engine::Fenced, "apply=#{apply.id} run_token=#{run_token}" if fenced?
  end

  def current_stage
    apply.stage
  end

  # Fenced write of engine columns (FencedUpdate), mirrored onto the in-memory apply without a reload.
  def persist!(**attributes)
    Apply::Operation::Engine::FencedUpdate.call(ctx: self, attributes:)
    apply.assign_attributes(attributes)
    apply.clear_attribute_changes(attributes.keys)
    attributes
  end

  # Appends one trace entry; keeps the newest MAX_TRACE. Values are stored as given: the Runner redacts on flush.
  def trace(event, **data)
    scratch.trace << { 'at' => Time.current.iso8601(3), 'event' => event.to_s, **data.deep_stringify_keys }
    scratch.trace.shift while scratch.trace.size > MAX_TRACE
    nil
  end

  # Returns the trace entries collected since the last flush and starts an empty trace (the Runner stores them,
  # redacted, on the step row that just ended).
  def flush_trace!
    entries = scratch.trace
    scratch.trace = []
    entries
  end

  def http
    scratch.http ||= ApplyMate::Client::ImpersonateHttp.new(request_timeout: HTTP_TIMEOUT)
  end

  # ---------- browser session ----------

  def session
    scratch.session
  end

  # A new session starts with a fresh CookieConsent budget (banners come back in a new browser) and may open each
  # platform's canonical form URL once again.
  def session=(session)
    scratch.consent_clicks = 0
    scratch.canonical_unwrapped = []
    scratch.session = session
  end

  def session_open?
    !scratch.session.nil?
  end

  # The Runner opens a session scope around a unit of steps (`deadline` = the Session's own deadline) ...
  def open_scope!(scope, session, deadline)
    self.session = session
    scratch.scope = scope
    scratch.scope_deadline = deadline
  end

  # ... and closes it again in `ensure`: nothing may reach for a released lease afterwards.
  def close_scope!
    self.session = nil
    scratch.scope = nil
    scratch.scope_deadline = nil
  end

  # False once the platform gave a direct form URL AND the schema is known: the survey scope (navigate + discover)
  # is then not needed before answering.
  def survey_needed?
    !(platform&.canonical_form_url.present? && schema.present?)
  end

  # ---------- platform ----------

  def platform
    scratch.platform
  end

  def match
    scratch.match
  end

  def platform_known?
    match&.known? || apply.platform_known?
  end

  # Can the engine reach this application form? A known platform, or a generic match with a `probable` known platform
  # (a sub-threshold signal hit, e.g. Preply's ?ashby_jid= at the HTTP level) that the rendered landing page may
  # confirm (Engine::ReachForm's landing path). Phase 3a has no Navigator, so any other unknown platform cannot be
  # reached and keeps the legacy external path; phase 3b drops this predicate.
  def platform_reachable?
    platform_known? || match&.probable.present?
  end

  # Where a survey of a still unidentified platform starts: the final URL of the HTTP redirect walk (applies.landing_url,
  # persisted unredacted by DetectPlatform: the company careers page, not the job board's redirector), else the entry
  # URL. Never the stored step evidence: RedactTree mangles digit runs and token= / code= values in its URLs.
  def landing_url
    apply.landing_url.presence || entry_url
  end

  # Takes `match` as the run's detection and instantiates its adapter.
  def adopt_match!(match)
    scratch.match = match
    scratch.platform = Apply::Platform::Registry.find!(match.key).new(ctx: self, match:)
    match
  end

  # Merges new evidence (http or rendered level) and re-runs Detect. A different platform that crosses the
  # threshold replaces the adapter (at most MAX_PLATFORM_SWITCHES times per run, each traced); the same platform
  # (generic included, with its newer `probable`) is re-adopted with the richer captures; a below-threshold result
  # never demotes a known platform. Returns the match in force.
  def redetect!(evidence)
    scratch.evidence = scratch.evidence ? scratch.evidence.merge(evidence) : evidence
    found = Apply::Operation::Engine::Detect.call(evidence: scratch.evidence).model
    return adopt_match!(found) if match.nil? || found.key == match.key
    return match if found.generic?

    switch_platform!(found)
  end

  def evidence
    scratch.evidence
  end

  # Rehydrates the merged evidence of an earlier attempt (DetectPlatform.restore).
  def evidence=(evidence)
    scratch.evidence = evidence
  end

  # ---------- what the stages learned ----------

  def entry_url
    apply.entry_url.presence || apply.vacancy.external_url
  end

  def schema
    scratch.schema
  end

  def schema=(fields)
    scratch.schema = fields
  end

  # The platform's raw field keys of the schema (Field ids are "<platform key>:<raw key>"): what
  # Readiness.schema_keys looks for in the DOM.
  def schema_keys
    prefix = "#{match&.key}:"
    Array(schema).map { |field| field.id.delete_prefix(prefix) }
  end

  def fields
    scratch.fields
  end

  def fields=(fields)
    scratch.fields = fields
  end

  # What the answer stages work on: the survey's fields, else the persisted list (schema_api / earlier survey).
  def field_list
    fields.presence || apply.field_list
  end

  def form_root
    scratch.form_root
  end

  def form_root=(form_root)
    scratch.form_root = form_root
  end

  def form_url
    scratch.form_url || apply.form_url
  end

  def form_url=(url)
    scratch.form_url = url
  end

  # Host of the form (or, before it is known, of the entry URL): the default throttle key.
  def form_host
    URI.parse((form_url || entry_url).to_s).host&.downcase
  rescue URI::InvalidURIError
    nil
  end

  private

  def switch_platform!(found)
    if scratch.platform_switches >= MAX_PLATFORM_SWITCHES
      trace(:platform_switch_capped, from: match.key, to: found.key, confidence: found.confidence)
      return match
    end

    scratch.platform_switches += 1
    trace(:platform_switch, from: match.key, to: found.key, confidence: found.confidence)
    adopt_match!(found)
  end
end
