# frozen_string_literal: true

# Maps ambiguous form fields to canonical roles. Receives only the fields that
# deterministic mapping (scraper overrides, type, autocomplete) could not
# resolve — the AI never sees fields whose meaning is already known and never
# produces values here, only role names from the fixed vocabulary.
class Apply::Ai::Prompt::MapFields < ApplyMate::Ai::Prompt::Base
  PROMPT_TEMPLATE = <<~PROMPT
    You are classifying fields of a job-application form.

    For every field below, choose the single role from this vocabulary that best
    describes what the field asks for:

    PLACEHOLDER_ROLES

    Rules:
    - "custom_question" is the fallback for anything that does not clearly match
      another role (e.g. "Why do you want to join us?", "Years of React experience").
    - "cover_letter" is for the free-text message/motivation letter field.
    - Judge by the field's label, name, placeholder and options — not by position.

    Fields (each starts with its id in square brackets):
    PLACEHOLDER_FIELDS
  PROMPT

  def initialize(fields)
    @fields = fields
  end

  def call
    return if @fields.blank?

    fields_info = @fields.map { |field| render_field(field.to_h.stringify_keys) }.join("\n")

    PROMPT_TEMPLATE
      .sub('PLACEHOLDER_ROLES', Apply::CanonicalRoles::ALL.join(', '))
      .sub('PLACEHOLDER_FIELDS', fields_info)
  end

  private

  def render_field(field)
    line = "- [#{field['fingerprint']}] #{field['accessible_name'].presence || field['label'].presence || field['name']}"
    line += " (#{field['tag']}#{", type=#{field['type']}" if field['type'].present?})"
    line += ". Name: #{field['name']}" if field['name'].present?
    line += ". Placeholder: #{field['placeholder']}" if field['placeholder'].present?
    line += ". Section: #{field['fieldset']}" if field['fieldset'].present?

    if field['options'].present?
      option_labels = field['options'].map { |o| o['label'].presence || o[:label] }.compact.first(8)
      line += ". Options: #{option_labels.join(', ')}" if option_labels.any?
    end

    line
  end
end
