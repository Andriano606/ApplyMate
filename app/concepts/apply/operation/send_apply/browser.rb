# frozen_string_literal: true

class Apply::Operation::SendApply::Browser < Apply::Operation::Base
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
    @browser     = ApplyMate::Client::Browser.new
    @cv_tempfile = write_cv_tempfile(apply)

    inputs           = apply.filled_inputs || []
    trigger_selector = apply.trigger_selector
    submit_selector  = apply.submit_selector.presence || 'button[type="submit"]'

    @browser.navigate_to(apply.external_url)

    if trigger_selector.present?
      raise "Trigger element not found or not visible: #{trigger_selector}" unless @browser.click(trigger_selector)
      @browser.wait_for_idle
    end

    inputs.each do |input|
      input = input.with_indifferent_access
      next if input['type'] == 'file'
      next if input['value'].blank?
      @browser.fill_field(input['selector'], input['value'].to_s, input['tag'].to_s, form_index: input['form_index'])
    end

    if @cv_tempfile
      file_input = inputs.map { |i| i.with_indifferent_access }.find { |i| i['type'] == 'file' }
      @browser.attach_file(file_input, @cv_tempfile.path) if file_input
    end

    @browser.attempt_recaptcha_refresh

    raise "Submit button not found or not visible: #{submit_selector}" unless @browser.click(submit_selector, text: apply.submit_text)
    @browser.wait_for_idle(timeout: 15)

    attach_screenshot(apply, @browser.screenshot)
    verify_submit(apply, @browser.body)
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

  def verify_submit(apply, body)
    result = ApplyMate::Ai::AiHandler.call(
      prompt_instance:       Apply::Ai::Prompt::Browser::CheckSubmitResult.new(body),
      response_schema_class: Apply::Ai::ResponseSchema::Browser::CheckSubmitResult,
      ai_integration:        apply.ai_integration
    )
    raise result['reason'].presence || 'Submit verification failed' unless result['success']
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
