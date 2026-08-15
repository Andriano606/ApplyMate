# frozen_string_literal: true

# Opens the employer's page in a browser session that STAYS ALIVE for the rest
# of the pipeline (handler owns and quits it). Navigates to the application form
# with AI assistance (CheckFormPage over a compact page digest — the AI only
# picks selectors the digest provides), snapshots the fields with live handles
# (data-am-field) and stores the field IR in apply.form_data.
class Apply::Operation::External::PrepareSession < Apply::Operation::Base
  include Apply::Operation::FormExtractor

  def start_status
    :fetching_form
  end

  def error_status
    :failed_fetching_form
  end

  private

  def run!(apply:, handler:, **)
    external_url = apply.vacancy.external_url
    raise 'No external apply URL stored for this vacancy' if external_url.blank?

    # Reuse the session Resolve already opened (the page is on the resolved URL);
    # open a fresh one only when running standalone or after a lost session.
    browser = handler.browser
    unless browser&.alive?
      browser = ApplyMate::Client::Browser.new
      handler.browser = browser # handler owns the session and quits it after all steps
      browser.navigate_to(external_url)
    end

    # Give an SPA time to paint before judging the page (see wait_for_fields).
    browser.wait_for_fields

    snapshot         = browser.snapshot_fields
    form_selector    = nil
    trigger_selector = nil

    # The AI is only needed to FIND a form. Asking when one is already on screen
    # once reported a working Ashby form as missing — but a stray field is not a
    # form either: a vacancy page with a single language <select> was taken for
    # one, and the application (behind an "Apply now" link) was never reached.
    unless application_form?(snapshot['fields'])
      check_result  = check_form_page(apply, browser)
      form_selector = check_result['form_selector'].presence

      unless check_result['has_form']
        trigger_selector = reveal_form(browser, check_result)
        browser.wait_for_fields
        form_selector = check_form_page(apply, browser)['form_selector'].presence
      end

      snapshot = browser.snapshot_fields(scope_selector: form_selector)
      # The AI-picked container can be wrong or too narrow (SPA forms without a
      # <form> tag) — a scoped snapshot that finds nothing is not proof the page
      # has no form, so retry across the whole document before giving up.
      snapshot = browser.snapshot_fields if snapshot['fields'].blank? && form_selector.present?
    end

    fields = enrich_fields(merge_radio_groups(snapshot['fields'] || []))
    raise 'No form fields found on employer page' if fields.empty?

    submit = snapshot['submit'] || {}
    # Accessor-based update — must not wipe keys other steps stored (ats, resolved_url).
    apply.update!(
      external_url:,
      trigger_selector:,
      submit_handle:    submit['handle'],
      submit_selector:  submit['selector'].presence || 'button[type="submit"]',
      submit_text:      submit['text'].presence,
      inputs:           fields
    )
  end

  # Controls an application asks for. Any one of them means the page is asking
  # a candidate for something, not merely offering a filter or a language picker.
  APPLICATION_TYPES = %w[email file textarea tel].freeze
  APPLICATION_WORDS = /name|email|phone|resume|cv|letter|ім'я|прізвищ|пошт|телефон|резюме|лист/i

  def application_form?(fields)
    fillable = Array(fields).map { |f| f.to_h.stringify_keys }.reject { |f| f['type'] == 'hidden' }
    return false if fillable.size < 2

    fillable.any? { |f| APPLICATION_TYPES.include?(f['type']) } ||
      fillable.any? { |f| "#{f['accessible_name']} #{f['name']}".match?(APPLICATION_WORDS) } ||
      fillable.size >= 4
  end

  def check_form_page(apply, browser)
    digest = browser.page_digest
    raise 'Failed to read employer page' if digest.blank?

    ApplyMate::Ai::AiHandler.call(
      prompt_instance:       Apply::Ai::Prompt::CheckFormPage.new(digest),
      response_schema_class: Apply::Ai::ResponseSchema::CheckFormPage,
      ai_integration:        apply.ai_integration
    )
  end

  # Reveals the form IN THE SAME SESSION: clicks the AI-picked trigger or
  # navigates to the form page. Returns the trigger selector to replay after a
  # lost session (nil when navigation was used).
  def reveal_form(browser, check_result)
    if check_result['trigger_selector'].present?
      unique = browser.click_with_unique_path(check_result['trigger_selector'])
      raise "Trigger element not found or not visible: #{check_result['trigger_selector']}" if unique.blank?

      browser.wait_for_idle
      unique
    elsif check_result['form_url'].present?
      browser.navigate_to(check_result['form_url'])
      nil
    else
      raise 'AI could not locate an application form page'
    end
  end

  # role is filled by the AI mapping step (Phase 2); fingerprint keys recipes
  # and role mappings across sessions and users.
  def enrich_fields(fields)
    fields.map do |field|
      field.merge('fingerprint' => Apply::FieldFingerprint.call(field), 'role' => nil)
    end
  end
end
