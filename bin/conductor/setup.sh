#!/usr/bin/env bash
# Conductor-Linux "setup" script.
#
# Point the app's Settings → Setup script at this file. It runs once when a
# workspace (git worktree) is created and delegates to bin/conductor/setup.rb,
# which gives every workspace an isolated dev/test database, Elasticsearch
# namespace and a unique PORT (3001–3020).
set -euo pipefail

# The app sets CONDUCTOR_WORKSPACE_PATH and runs us with cwd = the worktree;
# fall back to PWD. We invoke the Ruby script RELATIVE to the worktree so its
# per-workspace isolation is computed from THIS checkout, not the root repo.
cd "${CONDUCTOR_WORKSPACE_PATH:-$PWD}"

# Make asdf-managed tools (ruby, foreman) and bun reachable in this shell.
export PATH="$HOME/.asdf/shims:$HOME/.asdf/bin:$HOME/.bun/bin:$PATH"

exec ruby bin/conductor/setup.rb "$@"
