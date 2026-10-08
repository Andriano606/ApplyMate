# frozen_string_literal: true

# One deterministic navigation op of a recipe (design §5.4, §12): DATA an adapter's navigation_recipe declares (and,
# from phase 6, a learned recipe stores) as a hash, replayed by Apply::Operation::Engine::ReachForm. The op only
# resolves its URL template and drives the Session; waiting for the form, gates and redetection belong to ReachForm.
#
# Phase 3a ships `goto` and `unwrap` (the canonical form URL); the Interpreter with `expect`, drift detection and the
# other ops arrive in phase 3b.
#
#   Apply::Recipe::Op::Base.parse!('op' => 'goto', 'url_template' => '{entry_url}').perform!(ctx)
#
# url_template placeholders (TEMPLATES): {entry_url} the apply's entry URL, {landing_url} the final URL of the HTTP
# redirect walk (Context#landing_url, else the entry URL), {canonical_form_url} the adapter's
# canonical form URL, {current} the session's current URL. Any other {placeholder} is rejected at parse time; a
# placeholder without a value at perform time raises ArgumentError (a broken adapter, not a site anomaly).
class Apply::Recipe::Op::Base
  OPS = { 'goto' => 'Apply::Recipe::Op::Goto', 'unwrap' => 'Apply::Recipe::Op::Unwrap' }.freeze
  TEMPLATES = {
    'entry_url' => ->(ctx) { ctx.entry_url },
    'landing_url' => ->(ctx) { ctx.landing_url },
    'canonical_form_url' => ->(ctx) { ctx.platform&.canonical_form_url },
    'current' => ->(ctx) { ctx.session.current_url }
  }.freeze
  PLACEHOLDER = /\{([a-z_]+)\}/

  class << self
    # The op a stored hash describes ({ 'op' =>, 'url_template' => }, string or symbol keys).
    def parse!(hash)
      attrs = hash.to_h.stringify_keys
      klass = classes[attrs['op'].to_s] || raise(ArgumentError, "unknown recipe op #{attrs['op'].inspect}")
      klass.new(url_template: attrs.fetch('url_template'))
    end

    def op
      OPS.key(name) || raise(NotImplementedError, "#{name} is not in #{self}::OPS")
    end

    private

    def classes
      @classes ||= OPS.transform_values(&:constantize).freeze
    end
  end

  attr_reader :url_template

  def initialize(url_template:)
    unknown = url_template.to_s.scan(PLACEHOLDER).flatten - TEMPLATES.keys
    raise ArgumentError, "unknown url_template placeholder(s) #{unknown.join(', ')}" if unknown.any?

    @url_template = url_template.to_s
  end

  def perform!(_ctx)
    raise NotImplementedError, "#{self.class} must define perform!"
  end

  def to_h
    { 'op' => self.class.op, 'url_template' => url_template }
  end

  # The URL this op opens in `ctx`'s run.
  def url(ctx)
    url_template.gsub(PLACEHOLDER) do
      name = Regexp.last_match(1)
      TEMPLATES.fetch(name).call(ctx).presence || raise(ArgumentError, "recipe placeholder {#{name}} has no value")
    end
  end
end
