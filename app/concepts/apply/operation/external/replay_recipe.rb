# frozen_string_literal: true

# Replays a learned recipe for this host: executes the stored navigation in the
# live session, re-snapshots the fields and — if the form fingerprint matches —
# stores the inputs with roles straight from the recipe's field_map. That skips
# FetchFields (CheckFormPage AI) and makes MapFields fully deterministic. It
# does NOT submit: the CV is generated later in the pipeline; submission goes
# through the normal Generic path using the recipe's submit meta.
# No recipe / mismatch / failure → record_failure! and the pipeline continues
# down the ordinary path. Never fails the apply.
class Apply::Operation::External::ReplayRecipe < Apply::Operation::Base
  def start_status
    :fetching_form
  end

  def error_status
    :failed_fetching_form
  end

  private

  def run!(apply:, handler:, **)
    host   = FormRecipe.normalize_host(apply.resolved_url.presence || apply.vacancy.external_url)
    recipe = host && FormRecipe.best_for(host)
    return if recipe.nil?

    browser = handler.browser
    return if browser.nil? || !browser.alive?

    replay(apply, browser, recipe)
  rescue Apply::Operation::Base::BlockedError
    raise
  rescue StandardError => e
    Rails.logger.warn("ReplayRecipe failed for #{apply.id}: #{e.message}")
    @recipe&.record_failure!
  end

  def replay(apply, browser, recipe)
    @recipe = recipe

    trigger_selector = execute_navigation(browser, recipe)

    snapshot = browser.snapshot_fields
    fields   = merge_roles(snapshot['fields'] || [], recipe)

    if FormRecipe.form_fingerprint_for(fields) != recipe.form_fingerprint
      Rails.logger.info("ReplayRecipe: fingerprint mismatch on #{recipe.host}, falling back")
      recipe.record_failure!
      return
    end

    submit = snapshot['submit'] || {}
    apply.update!(
      trigger_selector: trigger_selector,
      submit_handle:    submit['handle'],
      submit_selector:  submit['selector'].presence || recipe.submit_meta['selector'].presence || 'button[type="submit"]',
      submit_text:      submit['text'].presence || recipe.submit_meta['text'].presence,
      inputs:           fields,
      fields_source:    'recipe'
    )
  end

  def execute_navigation(browser, recipe)
    trigger_selector = nil
    Array(recipe.navigation).each do |step|
      step = step.to_h.stringify_keys
      next unless step['op'] == 'click'

      raise "Recipe navigation click failed: #{step['selector']}" unless browser.click(step['selector'])

      browser.wait_for_idle
      trigger_selector = step['selector']
    end
    trigger_selector
  end

  def merge_roles(fields, recipe)
    fields.map do |field|
      field = field.to_h.stringify_keys
      field = field.merge('fingerprint' => field['fingerprint'].presence || Apply::FieldFingerprint.call(field))
      field.merge('role' => recipe.role_for(field['fingerprint']))
    end
  end
end
