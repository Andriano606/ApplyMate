# frozen_string_literal: true

# Gets the open session onto the application form (design §5.4, FormReacher; §10.1 replay; §16 for the landing page),
# in this order:
#
# R. replay (`navigation:` given, the submit scope's ReachForm(replay: true) passes applies.navigation): the stored op
#    hashes through Recipe::Interpret, then readiness unless the recipe's own WaitFor set ctx.form_root. Drift (a stale
#    locator, a tab that did not open, a form that never got ready or failed R2) is traced `recipe_drift`, the drifted
#    op becomes the Navigator's heal hint, and the paths below take over from the page the replay left;
# 0. landing: the platform is not identified yet (generic) and the lease is fresh -> Recipe::Op::Goto('{landing_url}')
#    (the final URL of the redirect walk), then a bounded wait in which every poll snapshots the page, runs the
#    after_goto gates and redetects (LANDING_TIMEOUT when the HTTP level found a probable platform, e.g. Preply's
#    ?ashby_jid=, else IDENTIFY_TIMEOUT, cut short when nothing is probable and the page already renders a form:
#    #form_rendered?); a platform identified there has its schema read;
# 1. canonical: the adapter's canonical_form_url, at most once per platform per session
#    (ctx.scratch.canonical_unwrapped, kept by Recipe::Op::Unwrap) and the session is not already on it
#    (CheckApplyKey.normalized_url, host + path) -> Recipe::Op::Unwrap('{canonical_form_url}');
# 2. the adapter's navigation_recipe (op hashes);
# 3. nothing navigated (the session is already on the form, e.g. an embed that shows it): the current page, unless it
#    is blank;
# 4. the Navigator (Engine::Navigate, heal mode when the replay drifted) on a non-blank page. When it hands over to a
#    platform it identified, that adapter's paths 1-3 run once more; nothing ready then -> Halt(:not_a_form).
#
# Paths R, 1 and 2 run their ops through Recipe::Interpret (the one op runner: fence, new tabs, gates after every op,
# redetection, trace recipe_op); Drift there is traced and the path counts as not ready. After each path:
# Engine::WaitReady (platform readiness, READY_TIMEOUT clamped to the deadline) unless a WaitFor op already set
# ctx.form_root; never for an ai_only platform (Generic: only the Navigator's R2-accepted claim or a stored WaitFor
# says the form is there). Ready sets ctx.form_root (the readiness root in the frame that got ready) and ctx.form_url.
# Nothing reached -> Halt(:not_a_form, detail: 'form not reached').
#
# model = the navigation that worked: the landing goto (when there was one), then the ops of the path that reached the
# form ([] for the current page); before the Navigator's ops, the ops of the last path that moved the page without
# reaching the form (so a replay starts where the Navigator started), with any switch_tab Interpret inserted.
# Termination: one replay pass, at most one landing goto with one bounded wait, one canonical goto per platform, the
# recipe's finite op list, one readiness wait per path, one Navigator run (its own budgets) and one adapter pass after
# a hand-over.
class Apply::Operation::Engine::ReachForm < ApplyMate::Operation::Base
  READY_TIMEOUT = 30
  LANDING_TIMEOUT = 20
  IDENTIFY_TIMEOUT = 5
  BLANK_PAGES = [ '', 'about:blank' ].freeze

  def perform!(ctx:, navigation: nil, **)
    skip_authorize
    @ctx = ctx
    @navigated = false
    @trail = []
    @heal_hint = nil
    replayed = replay(navigation)
    return self.model = replayed if replayed

    landing = land
    self.model = landing + (unwrap_canonical || run_recipe || current_page || navigate!)
  end

  private

  attr_reader :ctx

  def replay(navigation)
    return if navigation.blank?

    ready_after(navigation)
  end

  def land
    return [] if ctx.match&.known? || ctx.landing_url.blank? || !blank_page?

    op = Apply::Recipe::Op::Goto.new(url_template: '{landing_url}')
    op.perform!(ctx)
    probable = ctx.match&.probable
    window = probable ? LANDING_TIMEOUT : IDENTIFY_TIMEOUT
    rendered = false
    identified = ctx.session.wait_until(timeout: ctx.clamp(window)) do
      next true if Apply::Operation::Engine::Observe.call(ctx:, event: :after_goto).model.known?

      rendered = !probable && form_rendered?
    end
    identified = identified == true && !rendered
    ctx.trace(:landed, platform: ctx.match&.key, identified:, form_rendered: rendered, url: ctx.session.current_url)
    read_schema if identified
    [ op.to_h ]
  end

  # The landing already renders a form (WaitReady::DEFAULT_MIN_FIELDS visible fillable controls): a platform that has
  # not shown its markers with the form on screen will not show them later, so the identify wait ends here.
  def form_rendered?
    wait_ready = Apply::Operation::Engine::WaitReady
    root = ApplyMate::Client::Browser::Target.css(wait_ready::DEFAULT_ROOT)
    ctx.session.ready?(root, timeout: 0, min_fields: wait_ready::DEFAULT_MIN_FIELDS)
  end

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

    ready_after([ Apply::Recipe::Op::Unwrap.new(url_template: '{canonical_form_url}') ])
  end

  def run_recipe
    hashes = ctx.platform&.navigation_recipe
    return if hashes.blank?

    ready_after(hashes)
  end

  def current_page
    return if @navigated || blank_page?

    ready? ? [] : nil
  end

  # The AI Navigator from the page the earlier paths left; never on a blank lease (nothing to look at).
  def navigate!
    raise Apply::Operation::Engine::Halt.new(:not_a_form, detail: 'form not reached') if blank_page?

    navigation = @trail + Apply::Operation::Engine::Navigate.call(ctx:, heal_hint: @heal_hint).model
    return navigation if ctx.form_root

    @navigated = false
    adapter = unwrap_canonical || run_recipe || current_page
    raise Apply::Operation::Engine::Halt.new(:not_a_form, detail: 'form not reached') if adapter.nil?

    navigation + adapter
  end

  def blank_page?
    BLANK_PAGES.include?(ctx.session.current_url.to_s)
  end

  # The performed ops when the form is ready after them, else nil; the ops that moved the page (or ran before a drift)
  # are kept as the Navigator's trail, a stored WaitFor never (it is what failed).
  def ready_after(ops)
    @navigated = true
    performed = Apply::Operation::Recipe::Interpret.call(ctx:, ops:).model
    return performed if ctx.form_root || ready?

    @trail = without_wait_for(performed)
    nil
  rescue Apply::Operation::Recipe::Drift => e
    ctx.trace(:recipe_drift, op: e.op&.to_h, detail: e.detail, url: ctx.session.current_url)
    @heal_hint = e.op
    @trail = without_wait_for(e.performed)
    nil
  end

  def without_wait_for(ops)
    ops.reject { |op| op['op'] == 'wait_for' }
  end

  def ready?
    return false if ctx.platform&.ai_only?

    root = Apply::Operation::Engine::WaitReady.call(ctx:, timeout: ctx.clamp(READY_TIMEOUT)).model
    ctx.trace(:form_ready, ready: !root.nil?, frame_path: root&.frame_path)
    return false if root.nil?

    ctx.form_root = root
    ctx.form_url = ctx.session.current_url
    true
  end
end
