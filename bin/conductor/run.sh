#!/usr/bin/env bash
# Conductor-Linux "run" script.
#
# Point the app's Settings → Run script at this file. Triggered by the Run
# button, it delegates to bin/conductor/run.rb which boots the shared Docker
# stack and starts the dev server (foreman + Procfile.conductor) on this
# workspace's own PORT, so every workspace runs independently side by side.
set -euo pipefail

cd "${CONDUCTOR_WORKSPACE_PATH:-$PWD}"
export PATH="$HOME/.asdf/shims:$HOME/.asdf/bin:$HOME/.bun/bin:$PATH"

exec ruby bin/conductor/run.rb "$@"
