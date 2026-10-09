# frozen_string_literal: true

# Runs the gates of the adopted platform (Apply::Gate::Registry.for; Generic's = DEFAULT before detection) that
# listen to `event`, in registry order (design §10.4). A gate returns nil when nothing is there, resolves an
# obstacle in place (CookieConsent: returns truthy) or raises Apply::Operation::Engine::Halt.
#
# Context per event:
#   :http_resolved                 evidence: (CollectHttpEvidence)
#   :after_goto, :after_action,    snapshot: (Session#snapshot_all with Registry.dom_markers, taken after the page
#   :before_submit, :after_submit  change); evidence is derived from it here
#
# model = names of the gates that resolved something.
class Apply::Operation::Engine::RunGates < ApplyMate::Operation::Base
  def perform!(ctx:, event:, snapshot: nil, evidence: nil, **)
    skip_authorize
    raise ArgumentError, "unknown gate event #{event.inspect}" unless Apply::Gate::Base::EVENTS.include?(event)

    evidence ||= snapshot && Apply::Operation::Engine::Detect::Evidence.from_snapshot(snapshot)
    raise ArgumentError, "gate event #{event} needs evidence: or snapshot:" if evidence.nil?

    self.model = gates(ctx, event).filter_map do |gate|
      gate.name if gate.new.call(ctx, event:, evidence:, snapshot:)
    end
  end

  private

  def gates(ctx, event)
    platform_class = ctx.platform&.class || Apply::Platform::Generic
    Apply::Gate::Registry.for(platform_class).select { |gate| gate.events.include?(event) }
  end
end
