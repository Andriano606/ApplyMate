# frozen_string_literal: true

# A widget driver (design §7.2): how ONE kind of control is written with trusted input and read back. Plugin class
# (like Apply::Handler / Apply::Platform): thin, one instance per write. The write -> settle -> read-back -> fallback
# loop, the obstruction guard and the Mismatch decision live in Apply::Operation::Engine::SetFieldValue; drivers only
# answer these:
#
#   self.handles?(field)        does this driver write field.kind? (Registry asks in DRIVERS order)
#   self.key                    'text', 'aria_combobox', ... stored as Apply::Field#widget at discovery
#   settle_kind                 Session#settle profile after a write (:key default; :click, :file)
#   write(value)                the first try; raise Apply::Widget::Mismatch when there is nothing to pick
#   fallback_write(value)       a second, different way to write (truthy), or nil when there is none
#   read                        ReadBack(displayed, invalid, error_text) from probe/read_value.js (attached-only)
#   expected_display(value)     what the control should show for `value`
#   accepts?(read_back, value)  read-back verdict: not invalid and MatchOption.same?(displayed, expected_display)
#
# `value` is the answer in the field's own terms (Answer::CoerceValue): text, a number, true / false, an option label
# or a list of them, or the path of the file to upload.
class Apply::Widget::Base
  ReadBack = Data.define(:displayed, :invalid, :error_text)

  class << self
    def handles?(_field)
      raise NotImplementedError, "#{name} must define handles?"
    end

    def key
      name.demodulize.underscore
    end
  end

  attr_reader :ctx, :field

  def initialize(ctx:, field:)
    @ctx = ctx
    @field = field
  end

  def settle_kind
    :key
  end

  def write(_value)
    raise NotImplementedError, "#{self.class} must define write"
  end

  def fallback_write(_value)
    nil
  end

  def read
    raw = session.probe(:read_value, target)
    ReadBack.new(displayed: raw['displayed'], invalid: raw['invalid'] == true, error_text: raw['error_text'])
  end

  def expected_display(value)
    value.to_s
  end

  def accepts?(read_back, value)
    !read_back.invalid && Apply::Operation::Engine::MatchOption.same?(read_back.displayed, expected_display(value))
  end

  private

  def session
    ctx.session
  end

  def target
    field.target
  end

  # The field's option ({ 'label', 'value' }) `value` names (MatchOption), or nil (none, several, dynamic options).
  def matched_option(value)
    options = field.options.is_a?(Array) ? field.options : []
    Apply::Operation::Engine::MatchOption.call(candidates: options, wanted: value.to_s).model
  end

  # The label of the field's option `value` names, else the value as text (dynamic options).
  def option_label(value)
    matched_option(value)&.fetch('label', nil) || value.to_s
  end

  # CSS for the field root (field.target.root, the snapshot's root_strategies), '' without one: scopes the label /
  # option lookups of styled controls to their own question.
  def root_selector
    strategy = Array(target.root).first
    return '' if strategy.nil?
    return strategy['css'] if strategy['css'].present?

    strategy.fetch('attr', {}).map { |name, value| "[#{name}=#{css_string(value)}]" }.join
  end

  def css_string(text)
    %("#{text.to_s.gsub(/["\\]/) { |char| "\\#{char}" }}")
  end

  def scoped_target(*selectors)
    strategies = selectors.compact.map { |selector| { 'css' => selector } }
    ApplyMate::Client::Browser::Target.new(frame_path: target.frame_path, strategies:, root: nil, readonly: false)
  end
end
