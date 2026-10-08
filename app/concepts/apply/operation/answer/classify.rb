# frozen_string_literal: true

# The semantic of a field (design §8.1), decided deterministically and never by the AI. Order:
#   platform key (Platform::Base#semantic_for) -> password flag -> file kind (cv) -> input kind (email / tel)
#   -> autocomplete attribute (Apply::Field#autocomplete, read from the snapshot) -> label lexicon (config/apply/field_semantics.yml, uk / en / ru) -> 'other'.
# The sensitive semantics (password, demographic, legal_status, consent_required, marketing_opt_in) are what
# Answer::Resolve keeps away from the AI. model = one of Apply::Field::SEMANTICS.
class Apply::Operation::Answer::Classify < ApplyMate::Operation::Base
  LEXICON = YAML.safe_load_file(Rails.root.join('config/apply/field_semantics.yml')).freeze
  PATTERNS = LEXICON.fetch('semantics').transform_values do |sources|
    Regexp.union(sources.map { |source| Regexp.new(source, Regexp::IGNORECASE) })
  end.freeze
  AFFIRM = LEXICON.fetch('affirm').freeze
  DECLINE = LEXICON.fetch('decline').freeze

  AUTOCOMPLETE = {
    'name' => 'full_name', 'given-name' => 'first_name', 'family-name' => 'last_name', 'email' => 'email',
    'tel' => 'phone', 'tel-national' => 'phone', 'address-level2' => 'location', 'country-name' => 'location',
    'current-password' => 'password', 'new-password' => 'password'
  }.freeze
  KIND_SEMANTICS = { 'email' => 'email', 'tel' => 'phone', 'file' => 'cv' }.freeze
  # Trailing required-marks, punctuation and "(...)" notes, cut before the (anchored) lexicon is matched:
  # "Phone number (with country code) *" -> "Phone number".
  TRAILER = /(?:[\s*:.?!]|\([^()]*\))+\z/

  # The label of the first option that matches a lexicon phrase list (AFFIRM / DECLINE), in phrase order; nil when the
  # field has no static options or none matches. The ONE phrase-to-option rule (Resolve#decline, ResolveConsent).
  def self.option_label_for(field, phrases)
    return unless field.option_kind? && field.options.is_a?(Array)

    phrases.lazy.filter_map do |phrase|
      Apply::Operation::Engine::MatchOption.call(candidates: field.options, wanted: phrase).model&.fetch('label')
    end.first
  end

  def perform!(field:, platform: nil, **)
    skip_authorize
    self.model = platform&.semantic_for(field).presence ||
                 password(field) ||
                 KIND_SEMANTICS[field.kind] ||
                 AUTOCOMPLETE[field.autocomplete.to_s.downcase.split.last] ||
                 from_lexicon(field) ||
                 'other'
  end

  private

  def password(field)
    'password' if field.semantic == 'password'
  end

  def from_lexicon(field)
    [ field.label, field.placeholder ].each do |raw|
      text = raw.to_s.squish.sub(TRAILER, '')
      next if text.empty?

      match = PATTERNS.find { |_semantic, pattern| pattern.match?(text) }
      return match.first if match
    end
    nil
  end
end
