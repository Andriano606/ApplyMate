# frozen_string_literal: true

# One deterministic navigation op of a recipe (design §5.4, §12): DATA an adapter's navigation_recipe declares, a
# stored applies.navigation holds (and, from phase 6, a learned recipe stores) as a hash. A recipe is a plain Array of
# op hashes; Apply::Operation::Recipe::Interpret runs it (new tabs, gates, redetection, drift). An op only drives the
# Session through the engine's guards (Engine::GuardAction for clicks / keys) and settles; it never decides anything.
#
#   Apply::Recipe::Op::Base.parse!('op' => 'click', 'target' => target.to_h).perform!(ctx)
#
# | op           | attributes                                   | does                                               |
# | goto         | url_template                                 | Session#goto(url template resolved in ctx)         |
# | unwrap       | url_template                                 | goto of the platform's canonical form URL          |
# | click        | target (Target#to_h)                         | GuardAction { click }, settle(:click)              |
# | press        | target, key (KEYS)                           | GuardAction { press }, settle(:key)                |
# | scroll       | target                                       | scroll_into_view, settle(:key)                     |
# | switch_tab   | index                                        | switch_to(index), settle_content                   |
# | wait_for     | root (CSS), frame_path, min_fields           | ready? (READY_TIMEOUT) -> ctx.form_root / form_url |
#
# URL templates only: goto / unwrap carry a url_template that starts with a TEMPLATES placeholder and holds no literal
# URL ("://"); a recipe never stores where the user went, only how to get there from the run's own URLs.
# parse! raises ArgumentError for an unknown op, an unknown attribute, a bad template or key, KeyError for a missing
# attribute: an invalid stored recipe fails before its first action.
class Apply::Recipe::Op::Base
  OPS = {
    'goto' => 'Apply::Recipe::Op::Goto', 'unwrap' => 'Apply::Recipe::Op::Unwrap', 'click' => 'Apply::Recipe::Op::Click',
    'press' => 'Apply::Recipe::Op::Press', 'scroll' => 'Apply::Recipe::Op::Scroll',
    'switch_tab' => 'Apply::Recipe::Op::SwitchTab', 'wait_for' => 'Apply::Recipe::Op::WaitFor'
  }.freeze
  # url_template placeholders: {entry_url} the apply's entry URL, {landing_url} the final URL of the HTTP redirect walk
  # (Context#landing_url, else the entry URL), {canonical_form_url} the adapter's canonical form URL, {current} the
  # session's current URL.
  TEMPLATES = {
    'entry_url' => ->(ctx) { ctx.entry_url },
    'landing_url' => ->(ctx) { ctx.landing_url },
    'canonical_form_url' => ->(ctx) { ctx.platform&.canonical_form_url },
    'current' => ->(ctx) { ctx.session.current_url }
  }.freeze
  PLACEHOLDER = /\{([a-z_]+)\}/

  class << self
    # The op a stored hash describes ({ 'op' => ..., attributes }, string or symbol keys).
    def parse!(hash)
      attrs = hash.to_h.stringify_keys
      klass = classes[attrs['op'].to_s] || raise(ArgumentError, "unknown recipe op #{attrs['op'].inspect}")
      attributes = attrs.except('op')
      unknown = attributes.keys - klass.attributes
      raise ArgumentError, "unknown attribute(s) #{unknown.join(', ')} of recipe op #{klass.op}" if unknown.any?

      klass.from_h(attributes)
    end

    def op
      OPS.key(name) || raise(NotImplementedError, "#{name} is not in #{self}::OPS")
    end

    # The attribute names of the op's hash (besides 'op').
    def attributes
      raise NotImplementedError, "#{name} must declare attributes"
    end

    def from_h(_attrs)
      raise NotImplementedError, "#{name} must define from_h"
    end

    private

    def classes
      @classes ||= OPS.transform_values(&:constantize).freeze
    end
  end

  def perform!(_ctx)
    raise NotImplementedError, "#{self.class} must define perform!"
  end

  def to_h
    raise NotImplementedError, "#{self.class} must define to_h"
  end

  # The Session#settle profile perform! ends with, or nil (the op waits its own way: goto, switch_tab, wait_for).
  def settle_kind
    nil
  end

  # The gate event Interpret runs after this op: :after_goto for a new document, :after_action otherwise.
  def gate_event
    :after_action
  end

  # True when the op may open a new tab (a click on a target=_blank link, a key that triggers window.open):
  # Interpret looks at Session#pages after it.
  def opens_tab?
    false
  end

  # True when a successful perform! leaves ctx.form_root set (the recipe's terminal readiness check).
  def reaches_form?
    false
  end

  private

  def head(hash)
    { 'op' => self.class.op }.merge(hash)
  end
end
