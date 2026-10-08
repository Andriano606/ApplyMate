# frozen_string_literal: true

# Rendered-level detection evidence (design §4.2): probe/detect.js in every frame (Session#snapshot_all with the
# registry's DOM markers) -> Detect::Evidence (every frame URL is a current URL; script / iframe srcs and marker
# counts of all frames). Pass `snapshot:` when the caller already took one after the same page change (one
# snapshot_all evaluates every frame; taking two is wasted time).
class Apply::Operation::Engine::CollectRenderedEvidence < ApplyMate::Operation::Base
  def perform!(session:, snapshot: nil, **)
    skip_authorize
    snapshot ||= session.snapshot_all(markers: Apply::Platform::Registry.dom_markers)
    self.model = Apply::Operation::Engine::Detect::Evidence.from_snapshot(snapshot)
  end
end
