# frozen_string_literal: true

# Extracts the profile facts (contact details, salary, work authorization, ...) from the CV with one AI call.
# Skipped while facts_cv_digest matches the CV. user_profiles.facts = { 'ai' => {...}, 'user' => {...} }: the AI
# result only replaces 'ai'; 'user' (edited by the user) is kept and wins in UserProfile#fact.
# Internal operation. Callers: UserProfile::Job::ExtractFacts (enqueued by Create/Update when the CV changed; the
# user's default integration, none -> facts stay nil) and Apply::Operation::Stage::AnswerFields (inline, with the
# apply's integration), so a profile whose facts were never extracted (created before facts existed, saved without
# an integration, a job that ran out of retries) gets them at its next apply: no absorbing "facts nil" state.
class UserProfile::Operation::ExtractFacts < ApplyMate::Operation::Base
  include ApplyMate::Logging

  def perform!(user_profile:, ai_integration: nil, **)
    skip_authorize
    self.model = user_profile
    digest = Digest::SHA256.hexdigest(user_profile.cv)
    return if user_profile.facts_cv_digest == digest

    ai_integration ||= user_profile.user.default_ai_integration
    if ai_integration.blank?
      log("no default AI integration for user_profile=#{user_profile.id}; facts not extracted")
      return
    end

    ai_facts = ApplyMate::Ai::AiHandler.call(
      prompt_instance:       UserProfile::Ai::Prompt::ExtractFacts.new(user_profile),
      response_schema_class: UserProfile::Ai::ResponseSchema::ExtractFacts,
      ai_integration:
    )
    user_profile.update!(
      facts:           { 'ai' => ai_facts, 'user' => (user_profile.facts || {})['user'] || {} },
      facts_cv_digest: digest
    )
  end
end
