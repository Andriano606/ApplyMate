# frozen_string_literal: true

# One fillable field of an application form (design §7.1). Replaces Apply::FormField / form_data['inputs'] (phase 4).
# Persisted as Apply#fields (an array of #to_h); the target is valid for ONE browser session only.
class Apply::Field < Data.define(
  :id,            # platform field_key | "f_" + signature + "_" + ordinal; unique per inventory
  :kind,          # one of KINDS
  :label, :description, :placeholder, :required, :multiple, :max_length, :accept,
  :autocomplete,  # the control's autocomplete attribute (snapshot), an Answer::Classify input | nil
  :options,       # [{ 'label' =>, 'value' => }] | 'dynamic' | nil
  :semantic,      # one of SEMANTICS
  :widget,        # driver key chosen at discovery
  :target,        # ApplyMate::Client::Browser::Target (phase 4 adds an HTTP form target)
  :signature,     # SHA1 of normalized label + kind + option labels (Apply::Field.signature_for)
  :ordinal,       # position among fields with an equal signature, DOM order inside form_root
  :default_value, # prefilled value read in the CURRENT session; never sent to AI, never persisted for hidden
  :condition,     # { 'field' => id, 'equals' => 'Other' } | nil
  :source         # one of SOURCES
)
  KINDS = %w[
    text email tel url number textarea rich_text select multiselect combobox autocomplete
    radio_group option_group checkbox checkbox_group file date range hidden
  ].freeze
  SEMANTICS = %w[
    full_name first_name last_name email phone linkedin github location salary cv cover_letter
    consent_required marketing_opt_in demographic legal_status password other
  ].freeze
  SOURCES = %w[schema_api snapshot].freeze
  OPTION_KINDS = %w[select multiselect combobox radio_group option_group checkbox_group].freeze
  TEXTAREA_KINDS = %w[textarea rich_text].freeze
  MULTI_KINDS = %w[multiselect checkbox_group].freeze

  TARGET_TYPES = {
    'browser' => 'ApplyMate::Client::Browser::Target'
  }.freeze

  def self.target_classes
    @target_classes ||= TARGET_TYPES.transform_values(&:constantize).freeze
  end

  def self.from_h(hash)
    attrs = hash.to_h.symbolize_keys
    target = attrs[:target] && target_classes.fetch(attrs[:target].stringify_keys.fetch('type')).from_h(attrs[:target])
    new(**members.index_with { |member| attrs[member] }, target:)
  end

  # The ONE signature implementation: SHA1 of the normalized label, kind and option labels.
  def self.signature_for(label:, kind:, option_labels:)
    parts = [ label, kind, *Array(option_labels) ].map { |part| part.to_s.downcase.squish }
    Digest::SHA1.hexdigest(parts.join("\n"))
  end

  def file?
    kind == 'file'
  end

  def fillable?
    kind != 'hidden'
  end

  def option_kind?
    OPTION_KINDS.include?(kind)
  end

  def textarea?
    TEXTAREA_KINDS.include?(kind)
  end

  # The ONE "takes a list of values" check (answers, review form, widgets): a multi kind, or `multiple` from the schema
  # (Ashby MultiValueSelect) / the DOM multiple attribute on any other kind.
  def multi_valued?
    MULTI_KINDS.include?(kind) || multiple == true
  end

  # Persisted form: hidden defaults (CSRF etc.) are dropped; they are re-read in the session that posts.
  def to_h
    super.merge(target: target&.to_h, default_value: kind == 'hidden' ? nil : default_value)
  end
end
