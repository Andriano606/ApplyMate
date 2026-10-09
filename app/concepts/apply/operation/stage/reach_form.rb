# frozen_string_literal: true

# Opens the application form in the scope's session (design §5.4, §6.3, §10.2, §16): Engine::ReachForm (the landing
# page for a platform not identified yet, the canonical form URL, the adapter's navigation recipe, the current page,
# else the AI Navigator; Halt(:not_a_form) when nothing reaches the form) and persists what worked: applies.navigation
# (the op list, e.g. [{ 'op' => 'goto', 'url_template' => '{landing_url}' }, { 'op' => 'unwrap', 'url_template' =>
# '{canonical_form_url}' }], or the Navigator's [goto {landing_url}, click, ..., wait_for]) and applies.form_url.
# ctx.form_root (the readiness / R2-accepted root in the frame where the form rendered) is what DiscoverFields reads.
# Every path either sets a form root or halts: there is no "succeeded without a form" result.
#
# A detection the rendered pages changed (generic -> ashby on Preply's careers page) is persisted like DetectPlatform
# persists its own: platform, platform_match and the apply key, after CheckApplyKey (Halt(:already_applied) for an
# unconfirmed duplicate of the now known posting).
#
# Survey scope: skipped on a later attempt while the match (key + captures) and the schema ids are unchanged; restore
# re-adopts the match this step persisted (applies.platform_match), the schema it read (FetchSchema.persisted_schema),
# form_url (applies.form_url) and form_root (the stored result). `replay: true` (submit scope): always runs (no digest)
# and replays the stored applies.navigation through Recipe::Interpret (Engine::ReachForm path R); on drift it reaches
# the form the survey's way, the Navigator healing with the drifted op as its hint. The navigation persisted
# afterwards is the one actually performed (with any switch_tab a click's new tab inserted, or the fallback's ops).
class Apply::Operation::Stage::ReachForm < Apply::Operation::Stage::Base
  stage :navigate

  def self.input_digest(ctx, replay: false, **)
    return if replay

    Digest::SHA256.hexdigest([ ctx.match&.to_h&.slice('key', 'captures'), Array(ctx.schema).map(&:id).sort ].to_json)
  end

  # Ids, URLs and captures come from the unredacted applies columns this stage persisted: the stored result went
  # through RedactTree, which rewrites digit runs of a URL or a UUID capture as {{phone}}.
  def self.restore(ctx, result)
    readopt_match(ctx, result['platform'])
    ctx.schema ||= Apply::Operation::Stage::FetchSchema.persisted_schema(ctx) if result['schema'].to_i.positive?
    ctx.form_url = ctx.apply.form_url.presence || result['form_url']
    ctx.form_root = ApplyMate::Client::Browser::Target.from_h(result['form_root']) if result['form_root']
  end

  def self.readopt_match(ctx, key)
    persisted = ctx.apply.platform_match
    return unless key.present? && persisted.is_a?(Hash) && persisted['key'] == key && ctx.match&.to_h != persisted

    ctx.adopt_match!(Apply::Operation::Engine::Detect::Match.from_h(persisted))
  end
  private_class_method :readopt_match

  private

  def run!(ctx:, replay: false, **)
    stored = ctx.apply.navigation if replay
    navigation = Apply::Operation::Engine::ReachForm.call(ctx:, navigation: stored).model
    persist_detection!(ctx)
    ctx.persist!(navigation:, form_url: ctx.form_url)
    step_result(navigation:, form_url: ctx.form_url, form_root: ctx.form_root.to_h, platform: ctx.match.key,
                schema: Array(ctx.schema).size)
  end

  def persist_detection!(ctx)
    match = ctx.match
    return if match.nil? || match.to_h == ctx.apply.platform_match

    apply_key = match.known? ? Apply::Operation::Engine::CheckApplyKey.call(ctx:).model : ctx.apply.apply_key
    ctx.persist!(platform: match.key, platform_match: match.to_h, apply_key:)
  end
end
