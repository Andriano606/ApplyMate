# frozen_string_literal: true

# Gets the open session onto the application form (design §5.4, FormReacher; §16 for the landing page), in this order:
#
# 0. landing: the platform is not identified yet (generic with a probable known platform, e.g. Preply's ?ashby_jid=
#    at the HTTP level) and the lease is fresh -> Recipe::Op::Goto('{landing_url}') (the final URL of the redirect
#    walk), then a bounded wait (LANDING_TIMEOUT) in which every poll snapshots the page, runs the after_goto gates
#    (cookie banner, Google Forms ...) and redetects from the rendered frames (an embed script injects its iframe
#    late). A platform identified here reads its schema now (FetchSchema ran while it was still generic), so
#    readiness can use the schema keys and discovery merges the schema. Still not identified -> model nil: phase 3a
#    has no Navigator, the caller keeps the legacy path (Handler::Dou);
# 1. unwrap the canonical form URL: the adapter has one, it was not opened yet for this platform in this session
#    (ctx.scratch.canonical_unwrapped) and the session is not already on it (CheckApplyKey.normalized_url, host +
#    path) -> Recipe::Op::Unwrap('{canonical_form_url}');
# 2. the adapter's navigation_recipe (op hashes, Recipe::Op::Base.parse!);
# 3. nothing navigated after the landing (the session is already on the form, e.g. an embed that shows it): the
#    current page, unless it is blank.
#
# After every op of paths 1-2: a snapshot, RunGates(:after_goto), rendered evidence -> ctx.redetect!. After each path:
# Engine::WaitReady (platform readiness, READY_TIMEOUT clamped to the deadline); ready sets ctx.form_root (the
# readiness root in the frame that got ready) and ctx.form_url (the session's URL). No path ready for a known
# platform -> Halt(:not_a_form, detail: 'form not reached').
#
# model = the navigation that worked ([op hash], [] for the current page; the landing goto first when there was one),
# what Stage::ReachForm persists, or nil for a platform that is still unknown.
# Termination: at most one landing goto with one LANDING_TIMEOUT wait, one canonical goto, the recipe's finite op list
# and one readiness wait per path.
class Apply::Operation::Engine::ReachForm < ApplyMate::Operation::Base
  READY_TIMEOUT = 30
  # How long the landing page may take to reveal its platform: Preply's careers SPA loads the Ashby embed script and
  # injects iframe#ashby_embed_iframe after its own render.
  LANDING_TIMEOUT = 20
  BLANK_PAGES = [ '', 'about:blank' ].freeze

  def perform!(ctx:, **)
    skip_authorize
    @ctx = ctx
    @navigated = false
    landing = land
    return self.model = nil unless ctx.match&.known?

    navigation = unwrap_canonical || run_recipe || current_page
    raise Apply::Operation::Engine::Halt.new(:not_a_form, detail: 'form not reached') if navigation.nil?

    self.model = landing + navigation
  end

  private

  attr_reader :ctx

  def land
    return [] if ctx.match&.known? || ctx.landing_url.blank? || !blank_page?

    op = Apply::Recipe::Op::Goto.new(url_template: '{landing_url}')
    op.perform!(ctx)
    identified = ctx.session.wait_until(timeout: ctx.clamp(LANDING_TIMEOUT)) { observe.known? }
    ctx.trace(:landed, platform: ctx.match&.key, identified: identified == true, url: ctx.session.current_url)
    read_schema if identified
    [ op.to_h ]
  end

  # nil from the adapter (no schema endpoint, or it failed and was traced): discovery reads the DOM.
  def read_schema
    return if ctx.schema.present?

    ctx.schema = ctx.platform.fetch_schema.presence
  end

  def unwrap_canonical
    platform = ctx.platform
    url = platform&.canonical_form_url
    return if url.blank? || ctx.scratch.canonical_unwrapped.include?(platform.class.key)

    normalized = Apply::Operation::Engine::CheckApplyKey.method(:normalized_url)
    return if normalized.call(url) == normalized.call(ctx.session.current_url)

    ctx.scratch.canonical_unwrapped << platform.class.key
    ready_after([ Apply::Recipe::Op::Unwrap.new(url_template: '{canonical_form_url}') ])
  end

  def run_recipe
    hashes = ctx.platform&.navigation_recipe
    return if hashes.blank?

    ready_after(hashes.map { |hash| Apply::Recipe::Op::Base.parse!(hash) })
  end

  # Only when no path navigated: after a navigation that did not get ready, waiting on the same page again would
  # only burn the deadline. A fresh lease (about:blank) has nothing to wait for.
  def current_page
    return if @navigated || blank_page?

    ready? ? [] : nil
  end

  def blank_page?
    BLANK_PAGES.include?(ctx.session.current_url.to_s)
  end

  def ready_after(ops)
    ops.each do |op|
      @navigated = true
      op.perform!(ctx)
      match = observe
      ctx.trace(:navigated, op: op.to_h['op'], platform: match.key, url: ctx.session.current_url)
    end
    ops.map(&:to_h) if ready?
  end

  # One rendered look at the page: snapshot -> after_goto gates -> rendered evidence -> redetect. Returns the match in
  # force.
  def observe
    session = ctx.session
    snapshot = session.snapshot_all(markers: Apply::Platform::Registry.dom_markers)
    Apply::Operation::Engine::RunGates.call(ctx:, event: :after_goto, snapshot:)
    evidence = Apply::Operation::Engine::CollectRenderedEvidence.call(session:, snapshot:).model
    ctx.redetect!(evidence)
  end

  def ready?
    root = Apply::Operation::Engine::WaitReady.call(ctx:, timeout: ctx.clamp(READY_TIMEOUT)).model
    ctx.trace(:form_ready, ready: !root.nil?, frame_path: root&.frame_path)
    return false if root.nil?

    ctx.form_root = root
    ctx.form_url = ctx.session.current_url
    true
  end
end
