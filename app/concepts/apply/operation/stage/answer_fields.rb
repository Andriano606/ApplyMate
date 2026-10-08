# frozen_string_literal: true

# The answers of the application, resolved without a browser (Answer::Resolve: facts, policy, ONE AI call) and
# persisted with the fields' semantics. The profile facts are extracted first when they are missing or stale
# (UserProfile::Operation::ExtractFacts, digest-guarded). Skipped on a later attempt while the fields, the CV, the
# user's facts, the prompt, the consent setting, the fields' classified semantics and the platform registry are unchanged; the answers themselves live in applies.answers, so restore has nothing to rebuild.
# GeminiScraping is allowed here: the browser lease is closed while the answers are made (the survey and the submit are
# separate scopes), so the "one thread, one browser" invariant holds.
class Apply::Operation::Stage::AnswerFields < Apply::Operation::Stage::Base
  stage :answer

  def self.input_digest(ctx, **)
    apply = ctx.apply
    # The semantic each field classifies to NOW (platform key, autocomplete, the field_semantics.yml lexicon), not the
    # stored one: a lexicon or platform change re-classifies, and a DiscoverFields re-run (Registry.fingerprint, below,
    # is in its digest too) re-persists the semantics it reset to nil instead of skipping past them.
    fields = ctx.field_list.map do |field|
      semantic = Apply::Operation::Answer::Classify.call(field:, platform: ctx.platform).model
      [ field.id, field.kind, field.options, field.required, field.condition, semantic ]
    end
    template = apply.fill_form_prompt&.content || Apply::Ai::Prompt::AnswerFields::PROMPT_TEMPLATE
    profile = apply.user_profile
    # The CV digest, not facts['ai']: run! extracts the AI facts from that CV before answering, so a succeeded row
    # always had them, and their first extraction must not turn a resume into a re-answer (a new AI answer set would
    # void an approved review). The user's own facts change the answers directly.
    facts = [ Digest::SHA256.hexdigest(profile.cv.to_s), profile.facts&.dig('user').presence, profile.name, apply.user.email,
              apply.user.auto_consent ]
    # Not the apply's CV attachment: nothing here reads it, and GeneratePdfCv (after this stage) attaches it, so it
    # would differ on every resume and re-ask the AI, invalidating an approved review.
    Digest::SHA256.hexdigest([ fields, facts, template, apply.fill_form_prompt_id, Apply::Platform::Registry.fingerprint ].to_json)
  end

  private

  def run!(ctx:, **)
    return step_result(answers: 0) if ctx.field_list.empty?

    # A no-op while facts_cv_digest matches the CV (the usual case: Create/Update enqueued the extraction).
    UserProfile::Operation::ExtractFacts.call(user_profile: ctx.apply.user_profile, ai_integration: ctx.apply.ai_integration)
    resolved = Apply::Operation::Answer::Resolve.call(ctx:)
    answers = resolved.model
    ctx.persist!(answers:, fields: resolved[:fields].map(&:to_h))
    step_result(answers: answers.size)
  end
end
