# frozen_string_literal: true

# Field recovery (design §7.3 O7, `Engine::FieldRecovery`): a widget's write and its fallback did not stick
# (Apply::Widget::Mismatch); before Stage::FillFields gives the field up, the AI gets at most MAX_TURNS micro-turns to
# make the field accept the value with click / press only. Per turn:
#
#   1. snapshot_all(regions: [field root css]) -> the elements the AI may use: visible elements inside the field root
#      (field's frame), plus elements that are NEW since the last write (fingerprint absent from the mismatch's
#      `before` snapshot, i.e. what GuardAction saw before SetFieldValue wrote) in the field's frame or the top
#      document (portaled menus);
#   2. CallAi(Prompt::RecoverField, ResponseSchema::RecoverField; any integration, text mode without native JSON schema;
#      timeout capped by what is left of the budget); give_up -> stop; invalid output -> the error goes into the next
#      turn's prompt;
#   3. each action (<= MAX_ACTIONS) whose ref is one of those elements -> Engine::ExecuteAction(allowed: click press)
#      (it rejects submit_like / password / Enter in a control); a ref outside them is rejected without touching the
#      page (trace action_rejected, reason outside_field). Stops after an action that navigated;
#   4. at least one action performed -> SetFieldValue again: accepted -> model = its ReadBack (result[:approximate] as
#      SetFieldValue's); another Mismatch -> the next turn works from it.
#
# What makes it stop when the field never takes the value: MAX_TURNS (2 AI calls at most, each counted by CallAi),
# the monotonic budget (MAX_SECONDS plus the slow-AI allowance for MAX_TURNS calls, clamped to ctx.remaining; a turn
# needs CallAi::MIN_TIMEOUT left), give_up. Then the
# LAST Mismatch is raised again. The value never reaches the AI.
class Apply::Operation::Engine::RecoverField < ApplyMate::Operation::Base
  MAX_TURNS = 2
  MAX_SECONDS = 30
  ALLOWED = Apply::Ai::ResponseSchema::RecoverField::ACTION_TYPES
  MAX_ACTIONS = Apply::Ai::ResponseSchema::RecoverField::MAX_ACTIONS
  TOP_FRAME = 'f0'

  def perform!(ctx:, field:, value:, mismatch:, **)
    skip_authorize
    @ctx = ctx
    @field = field
    @root = root_css(mismatch.before)
    @stop_at = now + [ MAX_SECONDS + ctx.ai_allowance(MAX_TURNS), ctx.remaining ].min
    @errors = []
    last = mismatch
    1.upto(MAX_TURNS) do |turn|
      break if seconds_left < Apply::Operation::Engine::CallAi::MIN_TIMEOUT

      decision, snapshot, refs = ask(turn, last)
      next if decision.nil?
      break if decision['give_up']
      next unless act(decision['actions'], snapshot, refs)

      return recovered(turn, Apply::Operation::Engine::SetFieldValue.call(ctx:, field:, value:))
    rescue Apply::Widget::Mismatch => e
      last = e
    end
    ctx.trace(:field_unrecovered, field: field.id, widget: field.widget)
    raise last
  end

  private

  attr_reader :ctx, :field

  def ask(turn, mismatch)
    snapshot = ctx.session.snapshot_all(regions: [ @root ].compact)
    elements, fresh = usable(snapshot, mismatch.before)
    prompt = Apply::Ai::Prompt::RecoverField.new(field:, mismatch:, elements:, fresh:, turn:, max_turns: MAX_TURNS,
                                                 errors: @errors)
    @errors = []
    decision = Apply::Operation::Engine::CallAi.call(
      ctx:, prompt:, schema: Apply::Ai::ResponseSchema::RecoverField, system: prompt.system,
      timeout: seconds_left.floor
    ).model
    ctx.trace(:recover_turn, field: field.id, turn:, give_up: decision['give_up'], actions: decision['actions'].size,
                             reason: decision['reason'].to_s.truncate(300))
    [ decision, snapshot, elements.to_set { |element| element['ref'] } ]
  rescue *Apply::Operation::Engine::Navigate::INVALID_OUTPUT => e
    ctx.trace(:recover_invalid, field: field.id, turn:, error: e.message.truncate(300))
    @errors << "Your previous answer was invalid (#{e.message.truncate(200)}). Answer in the response format."
    nil
  end

  # [elements the AI may act on, refs among them that are new since the write]
  def usable(snapshot, before)
    known = before&.elements&.to_set { |element| element['fingerprint'] }
    fresh = []
    elements = snapshot.elements.select do |element|
      next false unless element['visible']

      same_frame = element['target'].frame_path == field.target.frame_path
      new = !known.nil? && !known.include?(element['fingerprint']) && (same_frame || element['frame'] == TOP_FRAME)
      fresh << element['ref'] if new
      new || (same_frame && Array(element['regions']).include?(@root))
    end
    [ elements, fresh ]
  end

  # true when at least one action was performed
  def act(actions, snapshot, refs)
    performed = 0
    Array(actions).first(MAX_ACTIONS).each do |action|
      next reject(action, 'outside_field') unless refs.include?(action['ref'])

      run = Apply::Operation::Engine::ExecuteAction.call(ctx:, action:, snapshot:, allowed: ALLOWED)
      next @errors << "#{describe(action)} was rejected: #{run[:rejected]}." if run[:rejected]

      performed += 1
      break if run[:navigated]
    end
    performed.positive?
  end

  def reject(action, reason)
    ctx.trace(:action_rejected, type: action['type'], ref: action['ref'], reason:)
    @errors << "#{describe(action)} was rejected: #{reason} (use only refs listed under FIELD ELEMENTS)."
  end

  def describe(action)
    "#{action['type']}(#{[ action['ref'], action['key'] ].compact.join(', ')})"
  end

  def recovered(turn, call)
    ctx.trace(:field_recovered, field: field.id, widget: field.widget, turn:)
    result[:approximate] = call[:approximate]
    self.model = call.model
  end

  # The field root's css: the target's own root (styled controls), else the root_strategies of the element the
  # pre-write snapshot shows at the target's css path, else the control itself.
  def root_css(before)
    own = css_of(field.target.strategies)
    css_of(field.target.root) || element_root_css(before, own) || own
  end

  def element_root_css(before, own)
    return if before.nil? || own.nil?

    element = before.elements.find do |candidate|
      candidate['target'].frame_path == field.target.frame_path && css_of(candidate['strategies']) == own
    end
    element && css_of(element['root_strategies'])
  end

  def css_of(strategies)
    Array(strategies).filter_map { |strategy| strategy['css'] }.last
  end

  def seconds_left
    @stop_at - now
  end

  def now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
