# frozen_string_literal: true

# The semantic of a field (design §8.1), decided deterministically and never by the AI. Order:
#   platform key (Platform::Base#semantic_for) -> password flag -> file kind (see #file) -> input kind (email / tel)
#   -> autocomplete attribute (Apply::Field#autocomplete, read from the snapshot) -> label lexicon (config/apply/field_semantics.yml, uk / en / ru;
#   label, placeholder, and the description when the label is a generic name) -> 'other'.
# The sensitive semantics (password, demographic, legal_status, consent_required, marketing_opt_in) are what
# Answer::Resolve keeps away from the AI. model = one of Apply::Field::SEMANTICS.
class Apply::Operation::Answer::Classify < ApplyMate::Operation::Base
  LEXICON = YAML.safe_load_file(Rails.root.join('config/apply/field_semantics.yml')).freeze
  PATTERNS = LEXICON.fetch('semantics').transform_values do |sources|
    Regexp.union(sources.map { |source| Regexp.new(source, Regexp::IGNORECASE) })
  end.freeze
  AFFIRM = LEXICON.fetch('affirm').freeze
  DECLINE = LEXICON.fetch('decline').freeze
  CV_FILE = Regexp.union(LEXICON.fetch('cv_file').map { |source| Regexp.new(source, Regexp::IGNORECASE) }).freeze
  EXTRA_FILE = Regexp.union(LEXICON.fetch('extra_files').map { |source| Regexp.new(source, Regexp::IGNORECASE) }).freeze
  HELPER_CONTROL = Regexp.union(LEXICON.fetch('helper_controls').map { |source| Regexp.new(source, Regexp::IGNORECASE) }).freeze
  GENERIC_NAMES = (LEXICON.fetch('generic_names') + AFFIRM).map { |name| name.to_s.downcase }.to_set.freeze

  AUTOCOMPLETE = {
    'name' => 'full_name', 'given-name' => 'first_name', 'family-name' => 'last_name', 'email' => 'email',
    'tel' => 'phone', 'tel-national' => 'phone', 'address-level2' => 'location',
    'country' => 'country', 'country-name' => 'country',
    'current-password' => 'password', 'new-password' => 'password'
  }.freeze
  KIND_SEMANTICS = { 'email' => 'email', 'tel' => 'phone' }.freeze
  # File semantics the label lexicon may give a file input (Answer::Resolve leaves them to the user).
  FILE_SEMANTICS = %w[cover_letter].freeze
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

  # A file field whose label names the CV ("Resume/CV", "Add your resume or CV"): the only file field a missing
  # required mark is implied for.
  def self.cv_file?(field)
    [ field.label, field.placeholder ].any? { |text| CV_FILE.match?(text.to_s) }
  end

  # A resume-parse / import helper (config/apply/field_semantics.yml helper_controls), not a question of the form.
  def self.helper_control?(*texts)
    texts.any? { |text| HELPER_CONTROL.match?(text.to_s.squish) }
  end

  # A name that says nothing about the question: every `/`-separated part is an upload verb or an affirm word
  # ("Attach", "Upload file", "Acknowledge/Confirm"), or it has no letter at all (a "+380" dial code, "$", "1.").
  def self.generic_name?(name)
    return true if name.present? && !name.to_s.match?(/\p{L}/)

    parts = name.to_s.squish.downcase.sub(TRAILER, '').split(%r{\s*/\s*})
    parts.any? && parts.all? { |part| GENERIC_NAMES.include?(part) }
  end

  def perform!(field:, platform: nil, **)
    skip_authorize
    self.model = platform&.semantic_for(field).presence ||
                 password(field) ||
                 file(field) ||
                 KIND_SEMANTICS[field.kind] ||
                 AUTOCOMPLETE[field.autocomplete.to_s.downcase.split.last] ||
                 from_lexicon(field) ||
                 'other'
  end

  private

  def password(field)
    'password' if field.semantic == 'password'
  end

  # A file input, by its label first (never "every upload is the CV": the CV uploaded into a cover-letter or an
  # "additional files" slot is wrong data, and an implied-required extra upload blocks nothing but gets filled):
  #   resume-parse helper (helper_control?)                         -> other (BuildFieldInventory drops it anyway)
  #   cover / motivation letter (FILE_SEMANTICS via the lexicon)    -> cover_letter
  #   names the CV (cv_file?)                                       -> cv
  #   portfolio / additional files / other attachments (extra_files) -> other
  #   no label at all (blank, or only a generic "Attach" / "Upload") -> cv
  #   any other label: required -> cv (the one upload a form insists on is the CV), optional -> other
  def file(field)
    return unless field.kind == 'file'
    return 'other' if self.class.helper_control?(field.label, field.placeholder, field.description)

    semantic = from_lexicon(field)
    return semantic if FILE_SEMANTICS.include?(semantic)
    return 'cv' if self.class.cv_file?(field)
    return 'other' if [ field.label, field.placeholder, field.description ].any? { |text| EXTRA_FILE.match?(text.to_s) }
    return 'cv' if unlabelled?(field) || field.required

    'other'
  end

  def unlabelled?(field)
    [ field.label, field.placeholder ].all? { |text| text.blank? || self.class.generic_name?(text) }
  end

  # The label, the placeholder, and the description only when the label says nothing ("Acknowledge/Confirm").
  def from_lexicon(field)
    texts = [ field.label, field.placeholder ]
    texts << field.description if self.class.generic_name?(field.label)
    texts.each do |raw|
      text = raw.to_s.squish.sub(TRAILER, '')
      next if text.empty?

      match = PATTERNS.find { |_semantic, pattern| pattern.match?(text) }
      return match.first if match
    end
    nil
  end
end
