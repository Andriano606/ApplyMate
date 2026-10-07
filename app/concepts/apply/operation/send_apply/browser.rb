# frozen_string_literal: true

# Legacy browser submit (deleted in phase 3b): replays apply.filled_inputs on the external form in a browserd
# Session (Camoufox, trusted input, humanized cursor) and clicks submit once, after the claim.
#
# Everything that can fail without side effects (trigger, fill + read-back, CV upload, the submit button's
# presence) happens before Apply::Operation::Engine::ClaimSubmit; from the claim on, every halt lands in
# submit_unverified (claim rule). The AI verdict on the page after the click runs once the lease is released.
class Apply::Operation::SendApply::Browser < Apply::Operation::Base
  # The positional fallback of a field: the n-th form control of the page, counted like FormExtractor's
  # form_index (submit/button/image/reset inputs excluded).
  FORM_CONTROLS_CSS = 'form input:not([type="submit"]):not([type="button"]):not([type="image"]):not([type="reset"]), ' \
                      'form textarea, form select'
  # Controls the replay leaves alone: hidden inputs belong to the page (their value came from it, and Playwright
  # cannot fill an invisible control); checkboxes/radios were never ticked by the legacy replay (it only rewrote
  # their value attribute) - option widgets arrive with phase 3.
  SKIPPED_TYPES = %w[file hidden checkbox radio].freeze
  # Seconds to wait for the form to render after the trigger click; a timeout is ignored (filling then fails
  # loudly on the first missing field).
  FORM_READY_TIMEOUT_S = 10

  stage :submit

  private

  def run!(apply:, ctx:, **)
    @cv_tempfile = write_cv_tempfile(apply)
    inputs = (apply.filled_inputs || []).map(&:with_indifferent_access)

    screenshot, body = submit_in_browser(apply, ctx, inputs)

    attach_screenshot(apply, screenshot)
    verify_submit(apply, body)
  end

  # model: [full-page PNG after the submit, page HTML after the submit]. humanize: true only here (the submit
  # lease, design §19); the form discovery lease runs without it.
  def submit_in_browser(apply, ctx, inputs)
    session_class = ApplyMate::Client::Browser::Session
    session_class.open(deadline: ctx.scope_deadline, owner: session_class.owner_for(apply), humanize: true,
                       identity: apply.hashid) do |session|
      session.goto(apply.external_url)
      open_form(session, apply.trigger_selector)
      fill(session, inputs)
      submit(session, ctx, apply.submit_selector.presence || 'button[type="submit"]', apply.submit_text)

      [ session.screenshot(full_page: true), session.html ]
    end
  end

  def open_form(session, trigger_selector)
    return if trigger_selector.blank?

    begin
      session.click(target_class.css(trigger_selector))
    rescue ApplyMate::Client::Browser::TargetNotFound
      halt!(:target_not_found, detail: trigger_selector)
    end
    session.settle(:click)
    session.ready?(target_class.css('form'), timeout: FORM_READY_TIMEOUT_S)
  end

  def fill(session, inputs)
    inputs.each do |input|
      next if SKIPPED_TYPES.include?(input['type']) || input['value'].blank?

      fill_field(session, input)
    end

    upload_cv(session, inputs.find { |input| input['type'] == 'file' })
  end

  # Writes the value, then reads it back: a field that does not hold the value afterwards halts the run before
  # the claim (no silent skips). Selects are chosen by option value; everything else is typed by Playwright.
  def fill_field(session, input)
    target = field_target(input)
    value  = input['value'].to_s
    if input['tag'] == 'select'
      session.select(target, value:)
    else
      session.fill(target, value)
    end
    session.settle(:key)

    actual = session.probe(:read_value, target)&.fetch('value', nil)
    halt!(:required_field_unfillable, detail: input['name']) unless same_value?(actual, value)
  end

  # Line breaks and surrounding whitespace are ignored: a single-line input drops line breaks (as the legacy replay
  # always did) and a textarea normalises \r\n. Anything else that differs (maxlength, an input mask, a framework
  # resetting the field) is a mismatch.
  def same_value?(actual, expected)
    normalize_value(actual) == normalize_value(expected)
  end

  def normalize_value(value)
    value.to_s.delete("\r\n").strip
  end

  def upload_cv(session, file_input)
    return if @cv_tempfile.nil? || file_input.nil?

    session.upload(field_target(file_input, fallback_css: 'input[type="file"]'), @cv_tempfile.path)
    session.settle(:file)
  end

  # Strategies in order: the stored selector, an optional generic selector, the field's position on the page.
  def field_target(input, fallback_css: nil)
    strategies = [
      ({ 'css' => input['selector'] } if input['selector'].present?),
      ({ 'css' => fallback_css } if fallback_css),
      ({ 'css' => FORM_CONTROLS_CSS, 'nth' => input['form_index'].to_i } unless input['form_index'].nil?)
    ].compact
    target_class.new(frame_path: [], strategies:, root: nil, readonly: false)
  end

  # A missing submit button is found before the claim (nothing was sent: failed, no claim). The claim is taken
  # right before the click; from then on every halt lands in submit_unverified (claim rule).
  def submit(session, ctx, selector, text)
    target = target_class.new(frame_path: [], strategies: [ { 'css' => selector, 'has_text' => text }.compact,
                                                            { 'css' => selector } ].uniq,
                              root: nil, readonly: false)
    halt!(:target_not_found, detail: selector) unless session.present?(target, visibility: :required)

    Apply::Operation::Engine::ClaimSubmit.call(ctx:)
    begin
      session.click(target)
    rescue ApplyMate::Client::Browser::TargetNotFound
      halt!(:target_not_found, detail: selector)
    end
    session.settle(:submit)
  end

  def target_class
    ApplyMate::Client::Browser::Target
  end

  def cleanup
    @cv_tempfile&.close!
  end

  def attach_screenshot(apply, screenshot_data)
    return if screenshot_data.blank?
    apply.screenshot.attach(
      io:           StringIO.new(screenshot_data),
      filename:     "screenshot_#{apply.id}.png",
      content_type: 'image/png'
    )
  end

  # The AI verdict alone never counts (design §11.4): neither "failed" nor a missing verdict releases the claim,
  # so both end in submit_unverified for the user to resolve ("It was sent" / "It was not sent"). A missing or
  # unparseable verdict (EmptyResponse / InvalidResponse) is mapped by the Runner (Run::ERROR_CODES ->
  # invalid_ai_output) and the claim rule; no second mapping here.
  def verify_submit(apply, body)
    result = ApplyMate::Ai::AiHandler.call(
      prompt_instance:       Apply::Ai::Prompt::Browser::CheckSubmitResult.new(body),
      response_schema_class: Apply::Ai::ResponseSchema::Browser::CheckSubmitResult,
      ai_integration:        apply.ai_integration
    )
    halt!(:validation_rejected, detail: result['reason']) unless result['success']
  end

  def write_cv_tempfile(apply)
    return nil unless apply.cv.attached?
    tmp = Tempfile.new([ apply.cv.filename.base, '.pdf' ])
    tmp.binmode
    apply.cv.download { |chunk| tmp.write(chunk) }
    tmp.flush
    tmp
  end
end
