# frozen_string_literal: true

# Browser submission as a perceive→act→verify loop instead of one shot. The
# first pass fills the pre-resolved inputs and presses submit; every following
# iteration observes the page (validation errors, new wizard steps, dynamic
# fields), asks the AI to plan actions — fill actions return ROLES, values
# resolve through Apply::ValueResolver — executes them and re-checks the
# deterministic submit signals. Blockers (captcha challenge, account/login
# walls) stop the loop with a specific blocked_* status BEFORE any AI spend.
class Apply::Operation::External::Generic < Apply::Operation::Base
  MAX_ITERATIONS = 6
  SUCCESS_TEXT   = /дяку|thank|success|отриман|received|надіслан|прийнят|submitted|applied/i
  SUCCESS_URL    = /thank|success|confirm|applied/i
  LOGIN_URL      = /login|signin|sign-in|auth/i

  # The site explicitly refused the submission (spam heuristics, rate limits,
  # server-side validation). Retrying is wrong on two counts: any retry that
  # slips through creates a DUPLICATE application, and repeated submits are
  # themselves the behaviour these filters look for. Checked before the success
  # patterns — "your application was not submitted" must never read as success.
  REJECTION_TEXT = /
    flagged\s+as\s+possible\s+spam | possible\s+spam | as\s+spam |
    couldn.?t\s+submit | could\s+not\s+submit | unable\s+to\s+submit | failed\s+to\s+submit |
    submission\s+(was\s+)?(rejected|blocked|flagged) |
    too\s+many\s+(attempts|requests) | rate\s+limit | try\s+again\s+later |
    не\s+вдалося\s+(надіслати|відправити) | спробуйте\s+ще\s+раз\s+пізніше
  /xi

  def start_status
    :sending_cv
  end

  def error_status
    :failed_sending_cv
  end

  def success_status
    :completed
  end

  private

  def run!(apply:, handler:, **)
    @apply       = apply
    @handler     = handler
    @cv_tempfile = write_cv_tempfile

    @browser    = live_browser || rebuild_session
    initial_url = apply.resolved_url.presence || apply.external_url

    initial_fill_and_submit
    @browser.wait_for_idle(timeout: 15)

    iteration = 0
    loop do
      state = @browser.observe_state
      check_blockers!(state)
      check_rejection!(state)
      break if submitted?(state, initial_url)

      iteration += 1
      give_up!(state, "Form not submitted after #{MAX_ITERATIONS} iterations") if iteration > MAX_ITERATIONS

      plan = plan_actions(state)
      check_blocked_plan!(plan, state)
      give_up!(state, 'AI returned no actions to progress the form') if plan['actions'].blank?

      execute_actions(plan['actions'], state)
      @browser.wait_for_idle
    end
  end

  def cleanup
    attach_screenshot # both success and failure — the screenshot is the evidence
    @cv_tempfile&.close!
    # handler owns the browser session and quits it after all steps
  end

  # ── Session ────────────────────────────────────────────────────────────────

  def live_browser
    browser = @handler&.browser
    browser if browser&.alive?
  end

  # Job retry: the session FetchFields opened is gone. Re-open the page, replay
  # the trigger click, re-snapshot and re-map stored values onto fresh handles.
  def rebuild_session
    browser = ApplyMate::Client::Browser.new
    @handler.browser = browser

    browser.navigate_to(@apply.external_url)

    if @apply.trigger_selector.present?
      raise "Trigger element not found or not visible: #{@apply.trigger_selector}" unless browser.click(@apply.trigger_selector)

      browser.wait_for_idle
    end

    @fresh_snapshot = browser.snapshot_fields
    browser
  end

  # ── First pass: pre-resolved values ────────────────────────────────────────

  def initial_fill_and_submit
    form_filler.fill(fillable_inputs)
    @browser.attempt_recaptcha_refresh
    click_submit
  end

  # Live path: filled_inputs carry valid handles. Rebuild path: re-map each
  # stored input onto the fresh snapshot by name, then label, then position.
  def fillable_inputs
    stored = (@apply.filled_inputs || []).map { |i| i.to_h.stringify_keys }
    return stored if @fresh_snapshot.nil?

    fresh = (@fresh_snapshot['fields'] || []).map { |f| f.to_h.stringify_keys }
    stored.map do |input|
      match = fresh.find { |f| f['name'].presence && f['name'] == input['name'] } ||
              fresh.find { |f| f['label'].presence && f['label'] == input['label'] } ||
              fresh.find { |f| f['form_index'] == input['form_index'] }
      match ? input.merge('handle' => match['handle'], 'selector' => match['selector']) : input
    end
  end

  # A failed submit click is not fatal — multi-step wizards have no submit
  # button on step one; the loop's AI plan presses the right button instead.
  def click_submit
    if @fresh_snapshot.nil? && @apply.submit_handle.present?
      return if @browser.click_by_handle(@apply.submit_handle)
    end

    selector = @apply.submit_selector.presence || 'button[type="submit"]'
    Rails.logger.info("Generic: submit click failed (#{selector}), leaving it to the loop") unless @browser.click(selector, text: @apply.submit_text)
  end

  # ── Blockers ───────────────────────────────────────────────────────────────

  def check_blockers!(state)
    raise BlockedError.new(:blocked_captcha, 'Captcha challenge on the page') if state['captcha']
    raise BlockedError.new(:blocked_login, "Redirected to a login page: #{state['url']}") if state['url'].to_s.match?(LOGIN_URL)

    visible_fields = Array(state['fields']).reject { |f| f['type'] == 'hidden' }
    if state['password_field'] && visible_fields.size <= 3
      raise BlockedError.new(:blocked_requires_account, 'The site requires creating an account')
    end
  end

  # Automation gave up but the situation is recoverable by a human: store the
  # last observed field IR for the review UI and mark the apply needs_review.
  # The user answers the open fields (→ AnswerBank, source: manual) and retries.
  def give_up!(state, message)
    @apply.update!(review_fields: Array(state['fields']))
    raise BlockedError.new(:needs_review, message)
  end

  # Stop the moment the site says it refused the submission — never re-click
  # submit, since a retry that succeeds would file a duplicate application.
  # The user finishes this one by hand (their answers are already in the bank).
  def check_rejection!(state)
    alerts = Array(state['alerts']).map { |text| text.to_s.squish }.reject(&:blank?)
    return if alerts.none? { |text| text.match?(REJECTION_TEXT) }

    # Keep every notice, not just the matching one — sites split the refusal
    # into a short headline plus the sentence that explains what to do next.
    give_up!(state, "Сайт відхилив автоматичну відправку: #{alerts.uniq.join(' — ').truncate(400)}")
  end

  def check_blocked_plan!(plan, state)
    return unless plan['status'] == 'blocked'

    case plan['blocked_reason']
    when 'captcha_v2'        then raise BlockedError.new(:blocked_captcha, 'AI reported a captcha challenge')
    when 'requires_account'  then raise BlockedError.new(:blocked_requires_account, 'AI reported an account wall')
    when 'login_wall'        then raise BlockedError.new(:blocked_login, 'AI reported a login wall')
    else
      # "cannot be automated" for an unnamed reason is a dead end for the user
      # unless we say WHERE it happened and hand over the answers — so this ends
      # as needs_review with the page named, not as a bare failure.
      give_up!(state, "Не вдалося заповнити форму автоматично на сторінці #{state['url']}. " \
                      'Скористайтесь ручною подачею нижче.')
    end
  end

  # ── Submit verification ────────────────────────────────────────────────────

  def submitted?(state, initial_url)
    alerts = Array(state['alerts']).join(' ')
    url    = state['url'].to_s

    return true if alerts.match?(SUCCESS_TEXT)
    return true if url.match?(SUCCESS_URL)
    return true if !state['form_present'] && url != initial_url

    # Form gone but no positive signal — ambiguous, AI is the tie-break.
    return verify_with_ai! unless state['form_present']

    false
  end

  def verify_with_ai!
    result = ApplyMate::Ai::AiHandler.call(
      prompt_instance:       Apply::Ai::Prompt::Browser::CheckSubmitResult.new(@browser.body),
      response_schema_class: Apply::Ai::ResponseSchema::Browser::CheckSubmitResult,
      ai_integration:        @apply.ai_integration
    )
    raise result['reason'].presence || 'Submit verification failed' unless result['success']

    true
  end

  # ── AI planning and execution ──────────────────────────────────────────────

  def plan_actions(state)
    ApplyMate::Ai::AiHandler.call(
      prompt_instance:       Apply::Ai::Prompt::PlanActions.new(state),
      response_schema_class: Apply::Ai::ResponseSchema::PlanActions,
      ai_integration:        @apply.ai_integration
    )
  end

  def execute_actions(actions, state)
    fields_by_handle = Array(state['fields']).map { |f| f.to_h.stringify_keys }.index_by { |f| f['handle'] }

    actions.each do |action|
      action = action.to_h.stringify_keys

      case action['op']
      when 'fill'   then execute_fill(action, fields_by_handle)
      when 'select' then execute_select(action, fields_by_handle)
      when 'upload' then @browser.attach_file_by_handle(action['handle'], @cv_tempfile.path) if @cv_tempfile
      when 'click'
        @browser.attempt_recaptcha_refresh if action['purpose'] == 'submit'
        @browser.click_by_handle(action['handle'])
      end
    end
  end

  def execute_fill(action, fields_by_handle)
    field = fields_by_handle[action['handle']]
    return if field.nil?

    field = field.merge('role' => action['role']) if action['role'].present?
    resolved = value_resolver.resolve([ field ]).first
    return if resolved['value'].blank?

    form_filler.fill([ resolved ])
  end

  def execute_select(action, fields_by_handle)
    field = (fields_by_handle[action['handle']] || { 'tag' => 'select', 'type' => 'select' }).dup
    form_filler.fill([ field.merge('value' => action['value'].to_s) ])
  end

  def form_filler
    @form_filler ||= Apply::FormFiller.new(browser: @browser, cv_path: @cv_tempfile&.path)
  end

  def value_resolver
    @value_resolver ||= Apply::ValueResolver.new(
      apply:        @apply,
      prompt_class: Apply::Ai::Prompt::FillForm,
      schema_class: Apply::Ai::ResponseSchema::FillForm
    )
  end

  # ── Artifacts ──────────────────────────────────────────────────────────────

  def attach_screenshot
    return if @browser.nil? || @apply.nil? || @apply.screenshot.attached?

    data = @browser.screenshot
    return if data.blank?

    @apply.screenshot.attach(
      io:           StringIO.new(data),
      filename:     "screenshot_#{@apply.id}.png",
      content_type: 'image/png'
    )
  rescue StandardError => e
    Rails.logger.error("Generic: screenshot capture failed: #{e.message}")
  end

  def write_cv_tempfile
    return nil unless @apply.cv.attached?

    tmp = Tempfile.new([ @apply.cv.filename.base, '.pdf' ])
    tmp.binmode
    @apply.cv.download { |chunk| tmp.write(chunk) }
    tmp.flush
    tmp
  end
end
