# frozen_string_literal: true

# Canonical vocabulary of application-form field roles. A role is what a field
# MEANS, decoupled from any job board's name attributes — AnswerBank stores
# answers per role, recipes map fingerprints to roles, and ResolveValues turns
# roles into values without AI for everything except free text.
module Apply::CanonicalRoles
  ALL = %w[
    full_name first_name last_name email phone city country
    linkedin github portfolio website
    cv_file cover_letter salary_expectation notice_period
    years_of_experience english_level work_authorization relocation remote_preference
    start_date referral_source consent_gdpr consent_marketing
    hidden_passthrough
    constant_false constant_true constant_empty
    custom_question
  ].freeze

  # Roles that resolve to a fixed value with no lookup at all.
  CONSTANT_VALUES = {
    'constant_false' => 'false',
    'constant_true'  => 'true',
    'constant_empty' => ''
  }.freeze

  # HTML autocomplete tokens with an unambiguous role.
  AUTOCOMPLETE_MAP = {
    'name'            => 'full_name',
    'given-name'      => 'first_name',
    'family-name'     => 'last_name',
    'email'           => 'email',
    'tel'             => 'phone',
    'url'             => 'website',
    'address-level2'  => 'city',
    'country'         => 'country',
    'country-name'    => 'country'
  }.freeze

  # Input types with an unambiguous role.
  TYPE_MAP = {
    'email'  => 'email',
    'tel'    => 'phone',
    'file'   => 'cv_file',
    'hidden' => 'hidden_passthrough'
  }.freeze

  # Deterministic mapping for one IR field: scraper override → type → autocomplete.
  # Returns nil when the field is ambiguous and needs the AI mapping step.
  def self.deterministic_role_for(field, overrides: {})
    field = field.to_h.stringify_keys
    overrides[field['name']].presence ||
      TYPE_MAP[field['type']].presence ||
      AUTOCOMPLETE_MAP[field['autocomplete']].presence
  end
end
