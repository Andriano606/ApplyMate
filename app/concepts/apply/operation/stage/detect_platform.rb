# frozen_string_literal: true

# Which platform the application form lives on (design §10.2, §4.2), before any browser lease:
#   CollectHttpEvidence (guarded redirect walk + final-page HTML scan)
#   -> RunGates(:http_resolved) (Google Forms, messengers, sign-in walls, DataDome, private hops)
#   -> Context#redetect! (Detect over the evidence; adopts the adapter, Generic below the threshold)
#   -> CheckApplyKey (Halt(:already_applied) for a confirmed-less duplicate)
#   -> persist platform, platform_match, apply_key, entry_url, landing_url (the walk's final URL)
# Every integration may drive any platform: an unknown one goes to Platform::Generic and the Navigator with whatever AI
# the user chose (owner decision 2026-10-09; see .ai/docs/apply_engine.md "AI budget").
# Skipped on a later attempt while the entry URL and Registry.fingerprint are unchanged (restore re-adopts the match
# and the evidence); a new adapter or signal makes it run again.
class Apply::Operation::Stage::DetectPlatform < Apply::Operation::Stage::Base
  stage :detect

  def self.input_digest(ctx, **)
    Digest::SHA256.hexdigest([ ctx.entry_url, Apply::Platform::Registry.fingerprint ].join("\n"))
  end

  # The stored step result went through RedactTree, which mangles strings (a UUID jid with a long digit run reads as a
  # phone number, token= / code= values are masked). Nothing Detect scores or the engine navigates by is taken from it:
  #   match         the unredacted applies.platform_match this stage persisted, when it names the same platform
  #   current_urls  [applies.landing_url] (unredacted); Context#landing_url reads that column too
  #   script_srcs, iframe_srcs, host_aliases  dropped: the rendered level (ReachForm's redetect) reads them again
  #   hops, dom_markers  kept: hops only feed host checks (gates, ReviewReasons) and never score; marker keys are
  #                      registry selectors and their values counts
  def self.restore(ctx, result)
    if result['evidence']
      stored = Apply::Operation::Engine::Detect::Evidence.from_h(result['evidence'])
      ctx.evidence = Apply::Operation::Engine::Detect::Evidence.build(
        current_urls: [ ctx.apply.landing_url ], hops: stored.hops, dom_markers: stored.dom_markers
      )
    end
    stored = result.fetch('match')
    persisted = ctx.apply.platform_match
    match = persisted.is_a?(Hash) && persisted['key'] == stored['key'] ? persisted : stored
    ctx.adopt_match!(Apply::Operation::Engine::Detect::Match.from_h(match))
  end

  private

  def run!(ctx:, **)
    entry_url = ctx.entry_url
    halt!(:no_application_path, detail: 'no entry url') if entry_url.blank?

    collected = Apply::Operation::Engine::CollectHttpEvidence.call(entry_url:, http: ctx.http)
    evidence = collected.model
    ctx.trace(:http_evidence, **{ hops: evidence.hops, fetch_error: collected[:fetch_error] }.compact)
    Apply::Operation::Engine::RunGates.call(ctx:, event: :http_resolved, evidence:)
    match = ctx.redetect!(evidence)
    ctx.trace(:detected, platform: match.key, confidence: match.confidence, probable: match.probable&.key)
    apply_key = Apply::Operation::Engine::CheckApplyKey.call(ctx:).model
    ctx.persist!(platform: match.key, platform_match: match.to_h, apply_key:, entry_url:,
                 landing_url: evidence.current_urls.first)
    step_result(match: match.to_h, evidence: evidence.to_h)
  end
end
