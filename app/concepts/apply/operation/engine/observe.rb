# frozen_string_literal: true

# One rendered look after a navigation or an action: snapshot_all (with the registry's DOM markers; pass `snapshot:`
# when the caller already took one after the same change) -> RunGates(event) -> CollectRenderedEvidence ->
# ctx.redetect!. model = the match in force; result[:resolved] = the gates that resolved something (a cookie banner
# clicked away: the snapshot is stale then), result[:snapshot] = the snapshot looked at.
class Apply::Operation::Engine::Observe < ApplyMate::Operation::Base
  def perform!(ctx:, event:, snapshot: nil, **)
    skip_authorize
    session = ctx.session
    snapshot ||= session.snapshot_all(markers: Apply::Platform::Registry.dom_markers)
    result[:resolved] = Apply::Operation::Engine::RunGates.call(ctx:, event:, snapshot:).model
    result[:snapshot] = snapshot
    evidence = Apply::Operation::Engine::CollectRenderedEvidence.call(session:, snapshot:).model
    self.model = ctx.redetect!(evidence)
  end
end
