# frozen_string_literal: true

# Performs ONE Navigator action (design §6.2, the closed vocabulary of ResponseSchema::Navigate) on the page the AI
# saw (`snapshot`): validates it, maps the element ref to its Target and runs the matching Recipe::Op, so a performed
# action is already a recipe op. Never types, fills or submits.
#
# Validation (a rejected action touches the session not at all, never raises):
#   type not in `allowed`                                     -> 'action_not_allowed'
#   click / press / scroll / navigate: ref not in the snapshot -> 'unknown_ref' (a hallucinated ref)
#   click / press on a submit_like or password element        -> 'submit_like' / 'password'
#   click / press on a file input's chooser link / button      -> 'file_trigger' (snapshot.js file_trigger: it only
#          opens the OS file dialog; the file field is uploaded by Widget::FileInput)
#   click / press on what sends the application by NAME       -> 'submit_like' (sends_application?, never on a link
#          that navigates: a ClassifyAdvance::FINAL_LEXICON verb on an element whose dialog / form scope holds a
#          visible fillable control, or a SnapshotAll::SUBMIT_TEXT verb outside any scope on a frame with visible
#          formless fields; a page launcher - "Apply now", "Надіслати резюме" opening a modal - stays clickable)
#   press: key not in Op::Press::KEYS                         -> 'unknown_key';
#          Enter on a fillable control                        -> 'implicit_submit' (Enter in a field submits its form)
#   navigate: no href                                         -> 'no_href'; the href resolved against the element's
#          frame URL must pass ResolvePublicAddress           -> 'private_address' (UnsafeUrlError: also non-http(s))
#          and not be a sign-in host (Gate::SignInWall.oauth_location) -> 'sign_in_host'
#   switch_tab: index outside session.pages                   -> 'unknown_tab'; a sign-in host -> 'sign_in_host'
#   a target gone by the time it is acted on (TargetNotFound) -> 'target_not_found'
# Every rejection is traced `action_rejected` (type, ref, reason).
#
# Execution: click / press / scroll -> Op::Click / Op::Press / Op::Scroll#perform! (GuardAction: gates first, one
# obstruction retry; a click / press that changed nothing gets one second look, SECOND_LOOK_SECONDS, after which the
# URL / tab count is read again); navigate -> session.goto(url) and the recorded op is Op::Click on the link (recipes
# hold URL templates only, never a literal URL); switch_tab -> Op::SwitchTab; wait -> session.wait_until (max_ms clamped to
# MAX_WAIT_MS) for the page digest to change, nothing recorded. After a click / press the new-tab rule
# (Engine::AdoptNewTab) may append a SwitchTab.
#
# model = the performed op hashes ([] when rejected); result[:rejected] = the reason or nil; result[:navigated] = the
# URL or the number of tabs changed; result[:page_changed] = navigated or the snapshot digest changed; result[:snapshot] = a fresh snapshot after the action
# (the Navigator's next observation; the AI's snapshot when rejected).
class Apply::Operation::Engine::ExecuteAction < ApplyMate::Operation::Base
  ALL_TYPES = Apply::Ai::ResponseSchema::Navigate::ACTION_TYPES
  REF_TYPES = %w[click press scroll navigate].freeze
  MAX_WAIT_MS = 5_000
  DEFAULT_WAIT_MS = 2_000
  # The late-render look after a click / press that changed nothing at its settle (second_look).
  SECOND_LOOK_SECONDS = 2.5
  SECOND_LOOK_TYPES = %w[click press].freeze
  OPS = { 'click' => Apply::Recipe::Op::Click, 'press' => Apply::Recipe::Op::Press, 'scroll' => Apply::Recipe::Op::Scroll }.freeze

  def perform!(ctx:, action:, snapshot:, allowed: ALL_TYPES, **)
    skip_authorize
    @ctx = ctx
    @snapshot = snapshot
    @action = action.to_h.stringify_keys
    @element = snapshot.elements.find { |element| element['ref'] == @action['ref'] } if @action['ref']
    reason = rejection(allowed)
    return reject(reason) if reason

    execute
  rescue ApplyMate::Client::Browser::TargetNotFound
    reject('target_not_found')
  end

  private

  attr_reader :ctx, :action, :element

  def session
    ctx.session
  end

  def rejection(allowed)
    type = action['type'].to_s
    return 'action_not_allowed' unless allowed.include?(type) && ALL_TYPES.include?(type)
    return 'unknown_ref' if REF_TYPES.include?(type) && element.nil?

    case type
    when 'click' then target_rejection
    when 'press' then press_rejection
    when 'navigate' then navigate_rejection
    when 'switch_tab' then tab_rejection
    end
  end

  def target_rejection
    return 'submit_like' if element['submit_like'] || sends_application?
    # A link / button around or beside a file input (snapshot.js file_trigger) only opens the OS file dialog.
    return 'file_trigger' if element['file_trigger']

    'password' if element['password']
  end

  # The no-submit guard by name, not only by the probe's submit_like (which needs a buttonish element with fields
  # nearby): a `<div role=button>Send application</div>` or a hallucinated pick of a dialog's type=button "Відгукнутися"
  # is refused before the claim. A send / apply verb counts only where it has something to send: inside a dialog / form
  # scope that holds a visible fillable control, or, outside any scope, on a frame with visible formless fields (an SPA
  # form without a <form>). Elsewhere ("Apply now", a `data-toggle=modal` "Надіслати резюме" on a landing page) it is
  # the launcher the Navigator has to click.
  def sends_application?
    return false if navigating_link?

    name = element['name'].to_s
    return false unless name.match?(Apply::Operation::Engine::ClassifyAdvance::FINAL_LEXICON)
    return scope_has_fields? if element['scope'].present?

    name.match?(ApplyMate::Client::Browser::Operation::SnapshotAll::SUBMIT_TEXT) && scope_has_fields?
  end

  # An <a> whose href leads somewhere (not "#", not javascript:): following it is a GET, never a form submission.
  def navigating_link?
    href = element['href'].to_s.strip
    element['tag'] == 'a' && href.present? && !href.start_with?('#') && !href.match?(/\Ajavascript:/i)
  end

  # A visible fillable control in the element's own scope (snapshot.js scopeOf: unique per dialog / form; nil = the
  # page itself, i.e. formless fields), other than the element itself ("Надіслати резюме" also reads as a CV chooser).
  def scope_has_fields?
    @snapshot.elements.any? do |other|
      other['ref'] != element['ref'] && other['frame'] == element['frame'] && other['scope'] == element['scope'] && other['visible'] &&
        Apply::Operation::Engine::BuildFieldInventory.control?(other)
    end
  end

  def press_rejection
    return 'unknown_key' unless Apply::Recipe::Op::Press::KEYS.include?(action['key'])

    target_rejection || ('implicit_submit' if action['key'] == 'Enter' && Apply::Operation::Engine::BuildFieldInventory.control?(element))
  end

  def navigate_rejection
    return 'no_href' if element['href'].blank?

    @url = absolute_url
    return 'private_address' if @url.nil?

    ApplyMate::Net::Operation::ResolvePublicAddress.call(url: @url)
    'sign_in_host' if Apply::Gate::SignInWall.oauth_location(@url)
  rescue ApplyMate::Net::UnsafeUrlError
    'private_address'
  end

  def absolute_url
    base = @snapshot.frames.find { |frame| frame['ref'] == element['frame'] }&.fetch('url', nil)
    URI.join(base.to_s, element['href']).to_s
  rescue URI::Error, ArgumentError
    nil
  end

  def tab_rejection
    pages = session.pages
    index = action['index']
    return 'unknown_tab' unless index.is_a?(Integer) && index >= 0 && index < pages.size

    'sign_in_host' if Apply::Gate::SignInWall.oauth_location(pages[index]['url'])
  end

  def reject(reason)
    ctx.trace(:action_rejected, type: action['type'], ref: action['ref'], reason:)
    result[:rejected] = reason
    result[:navigated] = false
    result[:page_changed] = false
    result[:snapshot] = @snapshot
    self.model = []
  end

  def execute
    before = { url: session.current_url, pages: session.pages.size }
    @fresh = nil
    ops = act
    fresh = @fresh || session.snapshot_all(markers: Apply::Platform::Registry.dom_markers)
    navigated = navigated?(before)
    if !navigated && fresh.digest == @snapshot.digest && SECOND_LOOK_TYPES.include?(action['type'])
      fresh = second_look(fresh)
      navigated = navigated?(before) # a delayed JS redirect during the look is a navigation (Navigate re-observes)
    end
    result[:rejected] = nil
    result[:snapshot] = fresh
    result[:navigated] = navigated
    result[:page_changed] = navigated || fresh.digest != @snapshot.digest
    self.model = ops
  end

  # A click / press whose effect renders late (an Angular uib-modal fades in ~1 s after the click, past the network-only
  # settle): one more look, at most SECOND_LOOK_SECONDS (clamped to the run's time), before "no change" makes the
  # action FORBIDDEN. Stops at the first changed snapshot or at the timeout, whichever comes first.
  # `fallback` (the post-action snapshot) stands when no look succeeds (every snapshot raised mid-navigation).
  def second_look(fallback)
    @fresh = nil
    session.wait_until(timeout: ctx.clamp(SECOND_LOOK_SECONDS)) do
      @fresh = session.snapshot_all(markers: Apply::Platform::Registry.dom_markers)
      @fresh.digest != @snapshot.digest
    end
    @fresh || fallback
  end

  def navigated?(before)
    session.current_url != before[:url] || session.pages.size != before[:pages]
  end

  def act
    case action['type']
    when 'navigate' then navigate
    when 'switch_tab' then perform_op(Apply::Recipe::Op::SwitchTab.new(index: action['index']))
    when 'wait' then wait
    else targeted
    end
  end

  def targeted
    target = element['target']
    op = action['type'] == 'press' ? OPS.fetch('press').new(target:, key: action['key']) : OPS.fetch(action['type']).new(target:)
    watch = Apply::Operation::Engine::AdoptNewTab.watch(ctx, target) if op.opens_tab?
    ops = perform_op(op)
    tab = watch && Apply::Operation::Engine::AdoptNewTab.call(ctx:, **watch).model
    tab ? ops + [ tab.to_h ] : ops
  end

  # The URL was checked by the validator; Session#goto checks it again (PublicAddressGuard) before navigating.
  def navigate
    session.goto(@url)
    [ Apply::Recipe::Op::Click.new(target: element['target']).to_h ]
  end

  def perform_op(op)
    op.perform!(ctx)
    [ op.to_h ]
  end

  # Records nothing; the snapshot the wait ended on (the change, or the last look at the timeout) is the fresh one.
  def wait
    max_ms = action['max_ms'].is_a?(Integer) ? action['max_ms'] : DEFAULT_WAIT_MS
    seconds = max_ms.clamp(0, MAX_WAIT_MS) / 1000.0
    session.wait_until(timeout: ctx.clamp(seconds)) do
      @fresh = session.snapshot_all(markers: Apply::Platform::Registry.dom_markers)
      @fresh.digest != @snapshot.digest
    end
    []
  end
end
