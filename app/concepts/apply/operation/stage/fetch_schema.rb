# frozen_string_literal: true

# The form's fields without a browser (design §10.2, O1): the adapter's `fetch_schema` (nil for Generic and for a
# schema endpoint that failed: the survey reads the DOM instead). A schema is persisted as applies.fields (source
# schema_api) together with form_url = the adapter's canonical_form_url. Skipped on a later attempt while the match
# key and captures are unchanged; restore rebuilds ctx.schema from applies.fields, but only when this stage found a
# schema (a generic run's schema comes from the landing page in ReachForm, which restores it itself).
class Apply::Operation::Stage::FetchSchema < Apply::Operation::Stage::Base
  stage :schema

  def self.input_digest(ctx, **)
    Digest::SHA256.hexdigest(ctx.match.to_h.slice('key', 'captures').to_json)
  end

  def self.restore(ctx, result)
    ctx.schema = persisted_schema(ctx) if result['fields'].to_i.positive?
  end

  # The schema fields among applies.fields (DiscoverFields keeps source schema_api on every field the schema named),
  # or nil. The one way a restore rebuilds ctx.schema (also Stage::ReachForm.restore).
  def self.persisted_schema(ctx)
    ctx.apply.field_list.select { |field| field.source == 'schema_api' }.presence
  end

  private

  def run!(ctx:, **)
    schema = ctx.platform&.fetch_schema
    return step_result(fields: 0) if schema.blank?

    ctx.schema = schema
    # A platform with a schema but no direct form URL keeps whatever form_url is known.
    ctx.persist!(**{ fields: schema.map(&:to_h), form_url: ctx.platform.canonical_form_url }.compact)
    step_result(fields: schema.size)
  end
end
