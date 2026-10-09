# frozen_string_literal: true

# The Generic AI Navigator (design §6.3): a bounded observe -> decide -> act loop from the current page to the
# application form, for a platform no adapter reaches (Engine::ReachForm calls it last). One turn:
#
#   tick        turn > MAX_TURNS -> Halt(:budget_exhausted); past the deadline (monotonic: MAX_SECONDS plus the slow-AI
#               allowance for Context::SCOPE_AI_CALLS calls, never past ctx.remaining) -> Halt(:deadline)
#   observe     snapshot (the previous action's fresh one when there is one) -> Engine::Observe: gates (:after_goto
#               after a navigation, :after_action otherwise: CookieConsent resolves, SignInWall / VisibleCaptcha /
#               Google Forms ... halt) and ctx.redetect!
#   hand over   the match switched to a known platform -> return (ReachForm continues with the adapter); a platform
#               with deterministic readiness whose form is ready within READY_TIMEOUT -> ctx.form_root, return
#   guard       the same (url, snapshot digest) for the STUCK_AFTER-th time -> Halt(:stuck)
#   decide      Engine::CallAi(Prompt::Navigate, ResponseSchema::Navigate; any integration: native JSON schema or text
#               mode, a slow one gets a longer deadline, see tick); an invalid or empty
#               answer is asked again once with the error (a counted call); MAX_INVALID_IN_A_ROW in a row ->
#               Halt(:invalid_ai_output)
#   give_up     -> Halt(give_up_code); captcha_challenge -> Halt(:manual_apply_required, detail: :captcha) (§18)
#   form_reached R2 on a fresh snapshot of the claimed root (AssessFormLikeness) + origin (CheckOrigin), traced
#               `form_claim`; accepted -> ctx.form_root / form_url, a terminal WaitFor appended, return; rejected ->
#               the next turn (already counted) with the reason in the prompt
#   continue    <= MAX_ACTIONS_PER_TURN actions through Engine::ExecuteAction against the snapshot the AI saw; an
#               action repeated from FORBIDDEN is skipped, a rejected one goes into the next prompt's errors; the batch
#               stops at the first page change; performed actions that changed nothing become FORBIDDEN
#
# What makes it stop when the page never cooperates: every turn counts (MAX_TURNS), the monotonic deadline, the stuck
# guard, two invalid answers in a row, and CallAi's caps (30 per attempt, 90 per apply). Turn state (@seen,
# @forbidden: the design's Guard; @turn, @deadline: its Budget) lives here, not in separate classes.
#
# model = the op hashes performed (Recipe ops; navigate is recorded as a click on the link), ending with WaitFor when
# the AI reached the form. On any raise nothing is persisted: Stage::ReachForm stores only a navigation that reached
# the form.
class Apply::Operation::Engine::Navigate < ApplyMate::Operation::Base
  # One parsed answer. status continue | form_reached | give_up; actions [Hash]; form Hash or nil.
  Decision = Data.define(:status, :reason, :actions, :form, :give_up_code) do
    # Raises InvalidResponse for an answer the schema allows but the loop cannot act on.
    def self.from_h(data)
      decision = new(status: data['status'].to_s, reason: data['reason'].to_s,
                     actions: Array(data['actions']).map { |action| action.to_h.stringify_keys },
                     form: data['form']&.to_h&.stringify_keys, give_up_code: data['give_up_code'])
      problem = decision.problem
      raise ApplyMate::Ai::ResponseSchema::Json::InvalidResponse, problem if problem

      decision
    end

    def problem
      case status
      when 'give_up' then 'give_up needs a give_up_code' if give_up_code.blank?
      when 'form_reached' then 'form_reached needs form.scope_ref' if form.nil? || form['scope_ref'].blank?
      when 'continue' then 'continue needs at least one action' if actions.empty?
      end
    end
  end

  MAX_TURNS = 12
  MAX_SECONDS = 180
  MAX_ACTIONS_PER_TURN = Apply::Ai::ResponseSchema::Navigate::MAX_ACTIONS
  STUCK_AFTER = 3
  MAX_INVALID_IN_A_ROW = 2
  # Seconds a platform with deterministic readiness gets per turn to show its form.
  READY_TIMEOUT = 2
  # Most visible fields the terminal WaitFor waits for (a replay must not drift on a field that renders late).
  WAIT_FOR_MAX_FIELDS = 3
  INVALID_OUTPUT = [ ApplyMate::Ai::ResponseSchema::Json::InvalidResponse, ApplyMate::Ai::Client::Base::EmptyResponse ].freeze
  # give_up codes whose Halt is not the code itself.
  GIVE_UP_HALTS = { 'captcha_challenge' => [ :manual_apply_required, :captcha ] }.freeze
  # A scope_ref with one of these roles is the form container itself; anything else is an element inside it.
  CONTAINER_ROLES = %w[dialog].freeze
  FORM_SEGMENT = /\Aform(:|\z)/

  def perform!(ctx:, heal_hint: nil, **)
    skip_authorize
    @ctx = ctx
    @heal_hint = heal_hint
    @turn = 0
    @deadline = now + [ MAX_SECONDS + ctx.ai_allowance(Apply::Operation::Engine::Context::SCOPE_AI_CALLS), ctx.remaining ].min
    @seen = Hash.new(0)
    @forbidden = []
    @recipe = []
    @errors = []
    @start_key = ctx.match&.key
    @ai_calls = ctx.apply.ai_calls.to_i
    @event = :after_action
    self.model = run
  end

  private

  attr_reader :ctx

  def run
    snapshot = nil
    loop do
      tick!
      snapshot = observe(snapshot)
      @posting_title ||= posting_title(snapshot)
      return @recipe if handed_over? || deterministic_ready?

      guard!(snapshot)
      decision = decide(snapshot)
      @previous = snapshot.elements.pluck('fingerprint')
      case decision.status
      when 'give_up' then give_up!(decision)
      when 'form_reached'
        return @recipe if accept_form?(decision.form, snapshot)

        snapshot = nil
      else
        snapshot = perform(decision.actions, snapshot)
      end
    end
  end

  def session
    ctx.session
  end

  def now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def tick!
    @turn += 1
    raise Apply::Operation::Engine::Halt.new(:budget_exhausted, detail: "navigator: #{MAX_TURNS} turns") if @turn > MAX_TURNS
    raise Apply::Operation::Engine::Halt.new(:deadline, detail: 'navigator time budget') if now > @deadline
  end

  # The gates and redetection on the page; a resolved obstacle (a cookie banner clicked away) makes the snapshot stale.
  def observe(snapshot)
    look = Apply::Operation::Engine::Observe.call(ctx:, event: @event, snapshot:)
    @event = :after_action
    return look[:snapshot] if look[:resolved].blank?

    session.snapshot_all(markers: Apply::Platform::Registry.dom_markers)
  end

  def handed_over?
    match = ctx.match
    return false unless match&.known? && match.key != @start_key

    ctx.trace(:navigator_handover, platform: match.key, turn: @turn)
    true
  end

  def deterministic_ready?
    platform = ctx.platform
    return false if platform.nil? || platform.ai_only?

    root = Apply::Operation::Engine::WaitReady.call(ctx:, timeout: ctx.clamp(READY_TIMEOUT)).model
    return false if root.nil?

    ctx.form_root = root
    ctx.form_url = session.current_url
    ctx.trace(:form_ready, ready: true, frame_path: root.frame_path)
    true
  end

  def guard!(snapshot)
    url = session.current_url
    key = [ url, snapshot.digest ]
    @seen[key] += 1
    return if @seen[key] < STUCK_AFTER

    raise Apply::Operation::Engine::Halt.new(:stuck, detail: "same page #{STUCK_AFTER} times: #{url}".truncate(300))
  end

  def decide(snapshot)
    invalid = 0
    loop do
      return ask(snapshot)
    rescue *INVALID_OUTPUT => e
      invalid += 1
      ctx.trace(:navigator_invalid, error: e.message.truncate(300), in_a_row: invalid)
      raise Apply::Operation::Engine::Halt.new(:invalid_ai_output, detail: e.message.truncate(200)) if invalid >= MAX_INVALID_IN_A_ROW

      @errors << "Your previous answer was invalid (#{e.message.truncate(200)}). Answer again in the response format."
    end
  end

  def ask(snapshot)
    @ai_calls += 1
    prompt = Apply::Ai::Prompt::Navigate.new(
      ctx:, snapshot:, previous: @previous, turn: @turn, max_turns: MAX_TURNS, ai_calls: @ai_calls,
      max_ai_calls: Apply::Operation::Engine::CallAi::MAX_AI_CALLS_PER_ATTEMPT, recipe: @recipe, forbidden: @forbidden,
      heal_hint: @heal_hint, last_action: @last_action, errors: @errors, posting_title: @posting_title
    )
    @errors = []
    call = Apply::Operation::Engine::CallAi.call(ctx:, prompt:, schema: Apply::Ai::ResponseSchema::Navigate, system: prompt.system)
    @ai_calls = call[:ai_calls] || @ai_calls
    decision = Decision.from_h(call.model)
    ctx.trace(:navigator_turn, turn: @turn, status: decision.status, reason: decision.reason.truncate(300),
                               actions: decision.actions.size)
    decision
  end

  # The landing page's own name for the vacancy (the first <h1> of the top frame, else its <title>), read once from the
  # first snapshot: the prompt shows it next to the job board's title when the two differ. Page-controlled text, so
  # the prompt renders it inside the untrusted block.
  def posting_title(snapshot)
    top = snapshot.frames.find { |frame| frame['parent'].nil? }
    return '' if top.nil?

    heading = Array(top['outline']).find { |line| line.to_s.start_with?('h1 ') }
    (heading&.delete_prefix('h1 ') || top['title']).to_s.squish
  end

  def give_up!(decision)
    code, detail = GIVE_UP_HALTS.fetch(decision.give_up_code) { [ decision.give_up_code.to_sym, decision.reason.truncate(200) ] }
    ctx.trace(:navigator_give_up, code: decision.give_up_code, reason: decision.reason.truncate(300))
    raise Apply::Operation::Engine::Halt.new(code, detail:)
  end

  # ---------- continue ----------

  # The snapshot to observe next: the last performed action's fresh one, or nil (a new look) when nothing ran.
  def perform(actions, snapshot)
    fresh = nil
    performed = []
    actions.first(MAX_ACTIONS_PER_TURN).each do |action|
      signature = signature_of(action, snapshot)
      if @forbidden.include?(signature)
        @errors << "#{describe(action)} was skipped: it is FORBIDDEN (it changed nothing before)."
        next
      end

      run = Apply::Operation::Engine::ExecuteAction.call(ctx:, action:, snapshot:)
      if run[:rejected]
        @errors << "#{describe(action)} was rejected: #{run[:rejected]}."
        @last_action = { action:, outcome: "rejected (#{run[:rejected]})" }
        next
      end

      @recipe.concat(run.model)
      ctx.trace(:navigate, action: action.slice('type', 'ref', 'key', 'index', 'max_ms').compact, url: session.current_url)
      performed << signature
      fresh = run[:snapshot]
      @last_action = { action:, outcome: run[:page_changed] ? 'page changed' : 'no change' }
      next unless run[:page_changed]

      @event = :after_goto if run[:navigated]
      return fresh
    end
    @forbidden |= performed
    fresh
  end

  # "<what> <verb>": the element's fingerprint (stable across turns, unlike its ref), the tab index or the page.
  def signature_of(action, snapshot)
    type = action['type'].to_s
    verb = type == 'press' ? "press:#{action['key']}" : type
    return "tab:#{action['index']} #{verb}" if type == 'switch_tab'
    return "page #{verb}" if type == 'wait'

    element = snapshot.elements.find { |candidate| candidate['ref'] == action['ref'] }
    "#{element ? element['fingerprint'] : action['ref']} #{verb}"
  end

  def describe(action)
    "#{action['type']}(#{action.slice('ref', 'key', 'index', 'max_ms').compact.values.join(', ')})"
  end

  # ---------- form_reached ----------

  def accept_form?(form, snapshot)
    root = root_of(form, snapshot)
    if root.nil?
      ctx.trace(:form_claim, accepted: false, reason: 'no_root', scope_ref: form['scope_ref'])
      @errors << "form_reached was rejected: #{form['scope_ref']} and the field refs do not locate a form on this page."
      return false
    end

    css, frame_path = root
    fresh = session.snapshot_all(markers: Apply::Platform::Registry.dom_markers, regions: [ css ])
    elements = fresh.elements.select { |element| element['target'].frame_path == frame_path }
    verdict = Apply::Operation::Engine::AssessFormLikeness.call(elements:, root: css).model
    origin = claim_origin(verdict)
    ctx.trace(:form_claim, accepted: verdict.accepted, reason: verdict.reason, fillable: verdict.fillable,
                           file_inputs: verdict.file_inputs, root: css, origin_ok: origin.model, host: origin[:host])
    return reject_claim(verdict) unless verdict.accepted

    ctx.form_root = ApplyMate::Client::Browser::Target.css(css, frame_path:)
    ctx.scratch.claim_left_out = left_out(form, snapshot, elements, css)
    min_fields = rendered_fields(ctx.form_root).clamp(1, WAIT_FOR_MAX_FIELDS)
    @recipe << Apply::Recipe::Op::WaitFor.new(root: css, frame_path:, min_fields:).to_h
    true
  end

  # The optional fillable controls inside the accepted root that the Navigator saw (in the prompt's snapshot) and
  # left out of `field_refs` - an "Autofill from resume" dropzone, a helper upload - by their css path
  # (BuildFieldInventory.dom_key); Stage::DiscoverFields leaves them out of the first page's inventory. Bounded: a
  # required control is never left out, and nothing is when the claim listed no field or left out more controls than
  # it listed (a sloppy claim must not empty the inventory).
  def left_out(form, snapshot, elements, root)
    inventory = Apply::Operation::Engine::BuildFieldInventory
    by_ref = snapshot.elements.index_by { |element| element['ref'] }
    listed = Array(form['field_refs']).filter_map { |ref| by_ref[ref] && inventory.dom_key(by_ref[ref]) }.to_set
    shown = snapshot.elements.filter_map { |element| inventory.dom_key(element) if element['visible'] }.to_set
    left = elements.select { |element| Array(element['regions']).include?(root) && inventory.control?(element) }
                   .reject { |element| element['required'] }
                   .filter_map { |element| inventory.dom_key(element) }
                   .select { |key| shown.include?(key) && listed.exclude?(key) }.to_set
    listed.empty? || left.size > listed.size ? Set.new : left
  end

  # The recipe's WaitFor is replayed by Session#ready? (probe/readiness.js), so its min_fields is measured by that same
  # probe now, not taken from the verdict (AssessFormLikeness counts choosers and groups, which readiness.js does not).
  def rendered_fields(root)
    session.probe(:readiness, root, { 'min' => 1 }).to_h['fields'].to_i
  end

  # CheckOrigin judges ctx.form_url: the page the form is on, kept only when the claim is accepted.
  def claim_origin(verdict)
    previous = ctx.scratch.form_url
    ctx.form_url = session.current_url
    origin = Apply::Operation::Engine::CheckOrigin.call(ctx:)
    ctx.scratch.form_url = previous unless verdict.accepted
    origin
  end

  def reject_claim(verdict)
    @errors << "form_reached was rejected (#{verdict.reason}): that is not the application form. Keep looking or give up."
    false
  end

  # [css, frame_path] of the claimed form root, or nil. A container scope (a dialog) is the root itself; otherwise
  # the root is the closest common ancestor of the scope, field, submit and advance elements in the scope's frame
  # (from their `tag:nth-of-type` css paths), widened to the enclosing <form> when there is one. The snapshot lists
  # interactive elements only, so a <form> / <div> container never has a ref of its own. Either path is then re-addressed
  # by #anchored.
  def root_of(form, snapshot)
    by_ref = snapshot.elements.index_by { |element| element['ref'] }
    scope = by_ref[form['scope_ref']]
    return if scope.nil?

    frame_path = scope['target'].frame_path
    path = CONTAINER_ROLES.include?(scope['role']) ? css_path(scope) : enclosing_css(members_of(form, by_ref, frame_path))
    path && [ anchored(path, frame_path), frame_path ]
  end

  def enclosing_css(members)
    common_ancestor(members.map { |element| css_path(element) })
  end

  def members_of(form, by_ref, frame_path)
    refs = [ form['scope_ref'], *Array(form['field_refs']), form['submit_ref'], form['advance_ref'] ].compact.uniq
    refs.filter_map { |ref| by_ref[ref] }.select { |element| element['target'].frame_path == frame_path }
  end

  # The root as probe/anchor.js re-addresses it: by a stable id / data-* / name / role+label of the root or of its
  # nearest such ancestor (`#form > div:nth-of-type(2)`), the document's only <form> as `form`; the snapshot's absolute
  # nth-of-type path only when nothing on the way up is stable. The stored WaitFor replays this selector, and a banner
  # inserted above the form must not shift it.
  def anchored(path, frame_path)
    session.probe(:anchor, ApplyMate::Client::Browser::Target.css(path, frame_path:)).to_h['selector'].presence || path
  rescue ApplyMate::Client::Browser::TargetNotFound
    path
  end

  def css_path(element)
    Apply::Operation::Engine::BuildFieldInventory.dom_key(element)
  end

  def common_ancestor(paths)
    return if paths.empty? || paths.any?(&:nil?)

    chains = paths.map { |path| path.split(' > ') }
    prefix = chains.first.take_while.with_index { |segment, index| chains.all? { |chain| chain[index] == segment } }
    prefix = prefix[0...-1] if chains.any? { |chain| chain == prefix }
    form_at = prefix.rindex { |segment| FORM_SEGMENT.match?(segment) }
    prefix = prefix[0..form_at] if form_at
    prefix.join(' > ').presence
  end
end
