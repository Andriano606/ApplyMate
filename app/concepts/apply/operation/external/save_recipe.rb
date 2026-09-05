# frozen_string_literal: true

# Records a successful browser-path application as a reusable recipe: the
# navigation that reached the form, the field→role map and the submit meta.
# Runs only after a completed submission, never changes the apply status and
# never fails the apply — losing a recipe is not worth failing a sent
# application.
class Apply::Operation::External::SaveRecipe < Apply::Operation::Base
  # No status transitions at all: this step runs after a successful submit and
  # must never knock the apply out of its final state — not on start, not on
  # its own errors.
  def perform!(apply:, handler: nil, **)
    skip_authorize
    self.model = apply
    return if apply.error.present?

    run!(apply:, handler:)
  rescue StandardError => e
    Rails.logger.error("SaveRecipe failed for #{apply.id}: #{e.message}")
  ensure
    cleanup
  end

  private

  def run!(apply:, **)
    return unless apply.completed?
    return if apply.fields_source == 'adapter' # ATS adapters need no recipe

    host = FormRecipe.normalize_host(apply.resolved_url.presence || apply.vacancy&.external_url)
    return if host.blank?

    fields = apply.inputs
    return if fields.blank?

    upsert_recipe(apply, host, fields)
  end

  def upsert_recipe(apply, host, fields)
    recipe = FormRecipe.find_or_initialize_by(
      host:             host,
      form_fingerprint: FormRecipe.form_fingerprint_for(fields)
    )

    recipe.ats         = apply.ats
    recipe.navigation  = navigation_for(apply)
    recipe.field_map   = field_map_for(fields)
    recipe.submit_meta = { 'selector' => apply.submit_selector, 'text' => apply.submit_text }.compact
    recipe.save!
    recipe.record_success!
  end

  def navigation_for(apply)
    return [] if apply.trigger_selector.blank?

    [ { 'op' => 'click', 'selector' => apply.trigger_selector } ]
  end

  def field_map_for(fields)
    fields.map do |field|
      field = field.to_h.stringify_keys
      {
        'fingerprint' => field['fingerprint'],
        'role'        => field['role'],
        'question'    => field['accessible_name'].presence || field['label']
      }.compact
    end
  end
end
