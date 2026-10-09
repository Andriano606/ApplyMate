# frozen_string_literal: true

# A platform adapter (design §4.1, §5.1): DATA about one ATS / form host, no procedure. The class level declares how
# to recognise the platform (signals), how often to submit to one tenant (throttle) and which gates apply; the
# instance (built by Context#adopt_match! with the run's ctx and Detect::Match) answers providers (nil = defer to the
# engine default) and hooks (defaults below). Stages call engine operations; adapters never drive a browser
# themselves, and real work (an HTTP schema fetch) is delegated to an operation.
#
# Adding a platform: .ai/docs/apply_engine.md, "Як додати нову платформу".
class Apply::Platform::Base
  Signal = Data.define(:kind, :pattern, :weight, :captures)
  SIGNAL_KINDS = %i[host url query_param frame_src script_src dom].freeze
  DEFAULT_THROTTLE = { interval: 10.minutes, key: ->(ctx) { "host:#{ctx.form_host}" } }.freeze

  # How the engine decides the form has rendered. kind :visible_fields (at least `min` visible fillable controls
  # under `root`) or :schema_keys (at least ceil(keys.size * ratio) of the schema keys present in `attr` under
  # `root`, any visibility); `root` is a CSS selector or nil (whole document). `key_prefix`: the platform's
  # per-render prefix of `attr` values as a regex source valid in both Ruby and JS (readiness.js strips it from the
  # start of each value); the same source must back the platform's #field_key, so the two cannot drift.
  Readiness = Data.define(:kind, :keys, :attr, :ratio, :min, :root, :key_prefix) do
    def self.visible_fields(root:, min: 1)
      new(kind: :visible_fields, keys: nil, attr: nil, ratio: nil, min:, root:, key_prefix: nil)
    end

    def self.schema_keys(keys:, attr:, root:, ratio: 0.8, key_prefix: nil)
      new(kind: :schema_keys, keys:, attr:, ratio:, min: nil, root:, key_prefix:)
    end
  end

  # What #field_key sees of one discovered control: the Snapshot element (probe/snapshot.js shape: 'attrs' holds
  # id / name / type / data-field-path of the field root ...) and the engine's default key for it.
  RawField = Data.define(:element, :default_key) do
    def attr(name)
      element.dig('attrs', name.to_s)
    end
  end

  class << self
    def signal(kind, pattern, weight:, captures: [])
      raise ArgumentError, "#{name}: unknown signal kind #{kind}" unless SIGNAL_KINDS.include?(kind)

      signals << Signal.new(kind:, pattern:, weight:, captures:)
    end

    # This class's own signals (not inherited, see #setting).
    def signals
      @signals ||= []
    end

    # Captures without which canonical_form_url / fetch_schema cannot work; a match lacking them stays below
    # Registry::THRESHOLD.
    def required_captures(*names)
      @required_captures = names if names.any?
      setting(:@required_captures, [])
    end

    def priority(value = nil)
      @priority = value if value
      setting(:@priority, 100)
    end

    # Minimum interval between SUBMITS to one tenant (AcquireHostSlot): { interval:, key: ->(ctx) { String } }.
    def throttle(interval = nil, key: nil)
      @throttle = { interval:, key: } if interval
      setting(:@throttle, DEFAULT_THROTTLE)
    end

    def extra_gates(*names)
      @extra_gates = names if names.any?
      setting(:@extra_gates, [])
    end

    def skipped_gates(*names)
      @skipped_gates = names if names.any?
      setting(:@skipped_gates, [])
    end

    def key
      name.demodulize.underscore
    end

    private

    # A declaration of this class, else the superclass's (a spec subclass pointing Ashby at FixtureSite keeps
    # required_captures, throttle and gates), else the default. Signals are NOT inherited: such a subclass
    # re-declares them from its own origin.
    def setting(ivar, default)
      return instance_variable_get(ivar) if instance_variable_defined?(ivar)
      return superclass.send(:setting, ivar, default) if superclass < Apply::Platform::Base

      default
    end
  end

  attr_reader :ctx, :match

  def initialize(ctx:, match:)
    @ctx = ctx
    @match = match
  end

  # ---------- providers (nil => defer) ----------

  # Direct URL of the application form, or nil.
  def canonical_form_url
    nil
  end

  # [Apply::Field] (source schema_api) from a public read-only endpoint, or nil.
  def fetch_schema
    nil
  end

  # Deterministic navigation ops from the current page to the form, or nil (recipes: phase 3b).
  def navigation_recipe
    nil
  end

  def answer_override(_field)
    nil
  end

  # The semantic the platform's own field key names (Answer::Classify asks first), or nil.
  def semantic_for(_field)
    nil
  end

  # Readiness, or nil (=> engine default), or :ai_only (Generic: only the Navigator's R2-accepted form_reached says
  # the form is there).
  def readiness
    nil
  end

  # True when nothing deterministic tells this platform's form has rendered (readiness :ai_only): Engine::ReachForm
  # never polls WaitReady for it, Engine::Navigate never hands back on readiness, DiscoverFields checks R2.
  def ai_only?
    readiness == :ai_only
  end

  # Canonical identity of the posting for cross-board duplicates, or nil (=> CheckApplyKey's normalized form URL).
  def apply_key
    nil
  end

  # ---------- data hooks with defaults ----------

  # CSS selectors whose controls are never fields (autofill panes).
  def excluded_regions
    []
  end

  def form_root_selector
    nil
  end

  # Stable identity of a discovered control across renders (RawField); must equal the schema Field id.
  def field_key(raw)
    raw.default_key
  end

  def answer_hints
    {}
  end

  def fill_order(fields)
    fields
  end

  # Positive evidence of an accepted submit only (Engine::VerifySubmit): texts / url_patterns (Regexps), submit_request
  # { url: Regexp, body_ok: ->(json) { bool } } or nil, and how many independent signals must agree. Optional:
  # selectors (CSS of the confirmation view in the form-root frame: the success_dom signal) and failure_selectors
  # (CSS of a "could not submit" view there: vetoes :submitted).
  def success_evidence
    { texts: [], url_patterns: [], selectors: [], failure_selectors: [], submit_request: nil, min_signals: 1 }
  end
end
