# frozen_string_literal: true

# The terminal op of a navigation that reaches a form (design §12 `expect: fields_visible >= n`): waits until the
# root (`root` CSS selector in the frame at `frame_path`) holds at least `min_fields` visible fillable controls
# (Session#ready?, READY_TIMEOUT clamped to the deadline). Ready -> ctx.form_root = that root, ctx.form_url = the
# session's URL; not ready -> Drift (the stored path no longer leads to the form).
class Apply::Recipe::Op::WaitFor < Apply::Recipe::Op::Base
  READY_TIMEOUT = Apply::Operation::Engine::ReachForm::READY_TIMEOUT

  def self.attributes
    %w[root frame_path min_fields]
  end

  def self.from_h(attrs)
    new(root: attrs.fetch('root'), frame_path: attrs.fetch('frame_path', []), min_fields: attrs.fetch('min_fields'))
  end

  attr_reader :root, :frame_path, :min_fields

  def initialize(root:, frame_path:, min_fields:)
    raise ArgumentError, 'recipe op wait_for: root must be a CSS selector' unless root.is_a?(String) && root.present?
    raise ArgumentError, 'recipe op wait_for: frame_path must be an Array' unless frame_path.is_a?(Array)
    raise ArgumentError, 'recipe op wait_for: min_fields must be an Integer >= 1' unless min_fields.is_a?(Integer) && min_fields.positive?

    @root = root
    @frame_path = frame_path.map { |hop| hop.to_h.stringify_keys }
    @min_fields = min_fields
  end

  def perform!(ctx)
    target = ApplyMate::Client::Browser::Target.css(root, frame_path:)
    ready = ctx.session.ready?(target, timeout: ctx.clamp(READY_TIMEOUT), min_fields:)
    raise Apply::Operation::Recipe::Drift.new(op: self, detail: "#{root} never held #{min_fields} field(s)") unless ready

    ctx.form_root = target
    ctx.form_url = ctx.session.current_url
  end

  def to_h
    head('root' => root, 'frame_path' => frame_path, 'min_fields' => min_fields)
  end

  def reaches_form?
    true
  end
end
