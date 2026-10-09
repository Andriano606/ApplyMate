# frozen_string_literal: true

# Has the application form rendered, and in which frame? (design §5.4) The platform's readiness
# (Platform::Base::Readiness: schema keys of the posting, or visible fillable controls) is checked under its root
# selector in every frame of the open session, top document first, until one frame is ready.
#
# model = the form root: a Target for the readiness root selector in that frame (the frame path the snapshot uses,
# e.g. [{ 'selector' => 'iframe#ashby_embed_iframe' }], so it compares equal to the snapshot elements' frame paths),
# or nil when no frame got ready within `timeout` seconds.
#
# Termination: Session#wait_until polls every 250 ms until `timeout` (clamped to the scope deadline by the session);
# each round probes at most Driver::Playwright::MAX_FRAMES frames once (ready? with timeout 0 never waits).
class Apply::Operation::Engine::WaitReady < ApplyMate::Operation::Base
  # Visible fillable controls the default readiness wants (no schema): fewer is a newsletter box, not an application.
  DEFAULT_MIN_FIELDS = 3
  DEFAULT_ROOT = 'body'

  # platform.readiness, else visible fields under the platform's form root (also for no platform yet). Callers never
  # ask for an ai_only platform (Generic): Engine::ReachForm and Engine::Navigate skip WaitReady for it.
  def self.readiness_of(platform)
    readiness = platform&.readiness
    return readiness if readiness.is_a?(Apply::Platform::Base::Readiness)

    Apply::Platform::Base::Readiness.visible_fields(min: DEFAULT_MIN_FIELDS,
                                                    root: platform&.form_root_selector || DEFAULT_ROOT)
  end

  def perform!(ctx:, timeout:, **)
    skip_authorize
    session = ctx.session
    readiness = self.class.readiness_of(ctx.platform)
    root = readiness.root || DEFAULT_ROOT
    frame = session.wait_until(timeout:) do
      frames(session).find { |candidate| ready_in?(session, readiness, root, candidate) }
    end
    self.model = frame ? form_root(session, root, frame) : nil
  end

  private

  # { url:, path: } of the top document and of every http(s) child frame (by URL: the cheap per-poll address).
  def frames(session)
    session.frames.first(ApplyMate::Client::Browser::Driver::Playwright::MAX_FRAMES).each_with_index.filter_map do |frame, index|
      url = frame['url'].to_s
      next { url:, path: [] } if index.zero?

      { url:, path: [ { 'url_contains' => url } ] } if url.match?(%r{\Ahttps?://}i)
    end
  end

  def ready_in?(session, readiness, root, frame)
    target = ApplyMate::Client::Browser::Target.css(root, frame_path: frame[:path])
    session.ready?(target, timeout: 0, **mode(readiness))
  end

  def mode(readiness)
    if readiness.kind == :schema_keys
      return { keys: readiness.keys, attr: readiness.attr, ratio: readiness.ratio, key_prefix: readiness.key_prefix }
    end

    { min_fields: readiness.min }
  end

  # A child frame is addressed like the snapshot addresses it (iframe#id hops when the iframe has an id), so the
  # elements DiscoverFields reads compare equal to the form root's frame path.
  def form_root(session, root, frame)
    path = frame[:path]
    if path.any?
      snapshot_frame = session.snapshot_all.frames.find { |candidate| candidate['url'] == frame[:url] }
      path = snapshot_frame['frame_path'] if snapshot_frame
    end
    ApplyMate::Client::Browser::Target.css(root, frame_path: path)
  end
end
