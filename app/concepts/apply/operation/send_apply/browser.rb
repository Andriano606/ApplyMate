# frozen_string_literal: true

class Apply::Operation::SendApply::Browser < Apply::Operation::Base
  stage :submit

  private

  def run!(apply:, ctx:, **)
    @browser     = ApplyMate::Client::Browser.new
    @cv_tempfile = write_cv_tempfile(apply)

    inputs = apply.filled_inputs || []

    @browser.navigate_to(apply.external_url)
    open_form(apply.trigger_selector)
    fill(inputs)
    @browser.attempt_recaptcha_refresh

    submit(ctx, apply.submit_selector.presence || 'button[type="submit"]', apply.submit_text)

    attach_screenshot(apply, @browser.screenshot)
    verify_submit(apply, @browser.body)
  end

  def open_form(trigger_selector)
    return if trigger_selector.blank?

    halt!(:target_not_found, detail: trigger_selector) unless @browser.click(trigger_selector)
    @browser.wait_for_idle
  end

  def fill(inputs)
    inputs.each do |input|
      input = input.with_indifferent_access
      next if input['type'] == 'file'
      next if input['value'].blank?
      @browser.fill_field(input['selector'], input['value'].to_s, input['tag'].to_s, form_index: input['form_index'])
    end

    return unless @cv_tempfile

    file_input = inputs.map { |i| i.with_indifferent_access }.find { |i| i['type'] == 'file' }
    @browser.attach_file(file_input, @cv_tempfile.path) if file_input
  end

  # A missing submit button is found before the claim (nothing was sent: failed, no claim). The claim is taken
  # right before the click; from then on every halt lands in submit_unverified (claim rule).
  def submit(ctx, selector, text)
    halt!(:target_not_found, detail: selector) unless @browser.clickable?(selector, text:)

    Apply::Operation::Engine::ClaimSubmit.call(ctx:)
    halt!(:target_not_found, detail: selector) unless @browser.click(selector, text:)
    @browser.wait_for_idle(timeout: 15)
  end

  def cleanup
    @browser&.quit
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
