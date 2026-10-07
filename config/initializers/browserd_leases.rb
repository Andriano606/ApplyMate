# frozen_string_literal: true

# Design §9.3: when a Solid Queue supervisor that serves the `apply` queue starts (SQ_ROLE apply/all),
# release every browserd lease still tagged with this host, so slots held by a crashed previous process
# are free before the apply workers start (Supervisor#start runs start hooks before start_processes, so
# no lease of the new process exists yet). The general worker (SQ_ROLE=general) never touches browserd
# and does not need BROWSERD_URL/BROWSERD_TOKEN.
#
# `on_start` (not an initializer body) is right here: nothing about browserd may abort boot, and the
# operation never raises on a missing/unreachable browserd — it logs a warning and returns nil.
#
# Scope: Browserd.owner_prefix = hostname + app dir + env. Kamal gives every new container a fresh
# hostname, so after a deploy the old container's leases are freed by browserd's reaper (its ws drops
# when the old process exits; ≤ ~45 s), and this sweep covers restarts of the same container. On a dev
# machine the app dir + env keep one workspace's `bin/dev` from killing another workspace's leases
# (or its own :browser spec run's).
SolidQueue.on_start do
  next if Apply::Operation::AssertQueueTopology.role == 'general'

  ApplyMate::Client::Browser::Operation::ReleaseOrphanLeases.call(
    owner_prefix: ApplyMate::Client::Browser::Browserd.owner_prefix
  )
end
