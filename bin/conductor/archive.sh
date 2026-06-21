#!/usr/bin/env bash
# Conductor-Linux "archive" script.
#
# Point the app's Settings → Archive script at this file. It runs right before
# the worktree is removed and delegates to bin/conductor/archive.rb, which drops
# this workspace's dev/test databases and Elasticsearch indexes (the shared
# Docker stack is left running for the other workspaces).
set -euo pipefail

cd "${CONDUCTOR_WORKSPACE_PATH:-$PWD}"
export PATH="$HOME/.asdf/shims:$HOME/.asdf/bin:$HOME/.bun/bin:$PATH"

exec ruby bin/conductor/archive.rb "$@"
