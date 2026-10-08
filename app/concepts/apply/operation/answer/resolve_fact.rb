# frozen_string_literal: true

# A profile fact for a semantic (design §8.1): UserProfile#fact (the user's own edit wins over the CV extraction).
# email falls back to the account's address, full_name to the profile name, languages are joined, cv is a FileRef.
# nil when nothing is known. Used by Answer::Resolve and by the AI prompt's facts block; demographic and
# work_authorization are only ever read here for the deterministic fields, never for the prompt.
class Apply::Operation::Answer::ResolveFact < ApplyMate::Operation::Base
  # semantic -> fact key (everything else uses the semantic itself as the key).
  FACT_KEYS = { 'legal_status' => 'work_authorization' }.freeze
  FACT_NAMES = (UserProfile::Ai::ResponseSchema::ExtractFacts::KEYS + %w[demographic]).freeze

  def perform!(semantic:, apply:, **)
    skip_authorize
    self.model = value_for(semantic.to_s, apply)
  end

  private

  def value_for(semantic, apply)
    return Apply::Operation::Answer::FileRef.cv if semantic == 'cv'

    key = FACT_KEYS.fetch(semantic, semantic)
    return unless FACT_NAMES.include?(key)

    value = apply.user_profile.fact(key).presence || fallback(key, apply)
    value.is_a?(Array) ? value.join(', ').presence : value
  end

  def fallback(key, apply)
    case key
    when 'email' then apply.user.email
    when 'full_name' then apply.user_profile.name
    end
  end
end
