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

    check_result     = check_form_page(apply, browser)
    form_selector    = check_result['form_selector'].presence
    trigger_selector = nil

    unless check_result['has_form']
      trigger_selector = reveal_form(browser, check_result)
      form_selector    = check_form_page(apply, browser)['form_selector'].presence
    end

    snapshot = browser.snapshot_fields(scope_selector: form_selector)
    fields   = enrich_fields(merge_radio_groups(snapshot['fields'] || []))
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
