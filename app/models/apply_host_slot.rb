# frozen_string_literal: true

# Per-tenant-host throttle row (AcquireHostSlot): the next time a browser run may touch the host, and the apply that
# holds it (holder_apply_id: that apply's own retry may take the slot again).
# One row per host_key; PruneApplySteps deletes rows idle for a day.
class ApplyHostSlot < ApplicationRecord
  self.primary_key = 'host_key'
end
