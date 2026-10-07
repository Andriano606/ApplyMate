#!/usr/bin/env bash
# browserd container entrypoint (runs as root with CAP_NET_ADMIN, then drops to uid browserd).
# Reference: .ai/docs/browser.md ("Network isolation").
#
# 1. Validates required env.
# 2. Installs the egress firewall: uid `browserd` (node + every Firefox it launches) may
#    only open TCP to 127.0.0.1:4750 (smokescreen) and to the 127.0.0.1-only Playwright
#    upstream ports of its own leases. Everything else, including DNS, is REJECTed.
#    Any failing rule aborts the start: browsers never run without the firewall.
# 3. Renders the smokescreen policy and starts smokescreen as uid `egress` on
#    127.0.0.1:4750 (the only uid with outbound network).
# 4. HEADLESS=virtual: starts Xvfb :99 as browserd.
# 5. exec node /app/server.mjs as browserd with no capabilities and no-new-privs.
#
# Environment read here (server.mjs documents the rest):
#   BROWSERD_TOKEN       REQUIRED (checked here and in server.mjs)
#   MAX_BROWSERS         REQUIRED, 1..3; sizes the upstream port range opened in iptables
#   WS_PORT_BASE         default 9301; upstream ports are WS_PORT_BASE+10 .. +10+MAX_BROWSERS-1
#   HEADLESS             true (default) | virtual (Xvfb :99 + headful Firefox) | false
#   EGRESS_ALLOW_RANGES  optional comma-separated entries smokescreen may reach even though they
#                        are private. An entry is a CIDR, or a hostname resolved once here
#                        (getent ahosts) into one /32 or /128 per address; an unresolvable
#                        hostname aborts the start. TEST ONLY: the docker-compose
#                        `browserd-test` service and CI set `host.docker.internal` so Firefox
#                        can load the fixture_site served from the docker host. Default empty =
#                        only public addresses. NEVER set it on the dev `browserd` service or
#                        staging/production: it opens that address to third-party page JS.
set -euo pipefail

SMOKESCREEN_PORT=4750
RUN_DIR=/run/browserd
CHAIN=BROWSERD_EGRESS

log() {
  printf '{"ts":"%s","level":"%s","msg":"entrypoint: %s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2"
}

die() {
  log fatal "$1"
  exit 1
}

[[ -n "${BROWSERD_TOKEN:-}" ]] || die "BROWSERD_TOKEN is required"
[[ "${MAX_BROWSERS:-}" =~ ^[1-3]$ ]] || die "MAX_BROWSERS must be 1..3, got '${MAX_BROWSERS:-}'"
WS_PORT_BASE="${WS_PORT_BASE:-9301}"
[[ "$WS_PORT_BASE" =~ ^[0-9]+$ ]] || die "WS_PORT_BASE must be an integer"
UPSTREAM_FIRST=$((WS_PORT_BASE + 10))
UPSTREAM_LAST=$((UPSTREAM_FIRST + MAX_BROWSERS - 1))
HEADLESS="${HEADLESS:-true}"
[[ "$HEADLESS" =~ ^(true|virtual|false)$ ]] || die "HEADLESS must be true|virtual|false, got '$HEADLESS'"

# ---------------------------------------------------------------- firewall

# Idempotent (own chain, flushed on restart). Every command is checked explicitly:
# errexit is suspended inside a function called from an `||` list.
apply_rules() {
  local ipt="$1"
  "$ipt" -w -N "$CHAIN" 2>/dev/null || "$ipt" -w -F "$CHAIN" || return 1
  "$ipt" -w -C OUTPUT -j "$CHAIN" 2>/dev/null || "$ipt" -w -I OUTPUT 1 -j "$CHAIN" || return 1
  "$ipt" -w -A "$CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT || return 1
  if [[ "$ipt" == iptables ]]; then
    "$ipt" -w -A "$CHAIN" -m owner --uid-owner browserd -o lo -d 127.0.0.1 -p tcp \
      --dport "$SMOKESCREEN_PORT" -j ACCEPT || return 1
    "$ipt" -w -A "$CHAIN" -m owner --uid-owner browserd -o lo -d 127.0.0.1 -p tcp \
      --dport "$UPSTREAM_FIRST:$UPSTREAM_LAST" -j ACCEPT || return 1
  fi
  "$ipt" -w -A "$CHAIN" -m owner --uid-owner browserd -j REJECT || return 1
}

ipv6_enabled() {
  [[ -d /proc/sys/net/ipv6/conf ]] || return 1
  local flag
  for flag in /proc/sys/net/ipv6/conf/*/disable_ipv6; do
    case "$flag" in */lo/* | */all/* | */default/*) continue ;; esac
    [[ "$(cat "$flag")" == 0 ]] && return 0
  done
  return 1
}

apply_rules iptables || die "iptables rules failed (is CAP_NET_ADMIN granted?)"
if ipv6_enabled; then
  apply_rules ip6tables || die "ip6tables rules failed while IPv6 is enabled"
else
  log info "IPv6 disabled on all interfaces, skipping ip6tables"
fi

as_browserd() {
  setpriv --reuid=browserd --regid=browserd --init-groups --inh-caps=-all --bounding-set=-all --no-new-privs "$@"
}

# The firewall must actually bite: a direct connection as browserd has to fail.
if as_browserd timeout 3 bash -c 'exec 3<>/dev/tcp/1.1.1.1/80' 2>/dev/null; then
  die "egress firewall is not effective: uid browserd reached 1.1.1.1:80 directly"
fi
log info "egress firewall installed (browserd -> 127.0.0.1:$SMOKESCREEN_PORT and :$UPSTREAM_FIRST-$UPSTREAM_LAST only)"

# ---------------------------------------------------------------- smokescreen

allow_ranges="[]"
if [[ -n "${EGRESS_ALLOW_RANGES:-}" ]]; then
  items=()
  IFS=',' read -ra ranges <<<"$EGRESS_ALLOW_RANGES"
  for range in "${ranges[@]}"; do
    range="${range// /}"
    if [[ "$range" =~ ^[0-9a-fA-F:.]+/[0-9]{1,3}$ ]]; then
      items+=("\"$range\"")
    elif [[ "$range" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then
      mapfile -t addresses < <(getent ahosts "$range" | awk '{print $1}' | sort -u)
      ((${#addresses[@]} > 0)) || die "EGRESS_ALLOW_RANGES host '$range' does not resolve"
      for address in "${addresses[@]}"; do
        if [[ "$address" == *:* ]]; then items+=("\"$address/128\""); else items+=("\"$address/32\""); fi
      done
    else
      die "EGRESS_ALLOW_RANGES entry is neither a CIDR nor a hostname: '$range'"
    fi
  done
  allow_ranges="[$(IFS=','; echo "${items[*]}")]"
  log warn "EGRESS_ALLOW_RANGES=$EGRESS_ALLOW_RANGES -> $allow_ranges reachable from browsers (test only)"
fi

mkdir -p "$RUN_DIR"
sed "s|__ALLOW_RANGES__|$allow_ranges|" /app/smokescreen.yaml.tmpl >"$RUN_DIR/smokescreen.yaml"
chmod 0644 "$RUN_DIR/smokescreen.yaml"

setpriv --reuid=egress --regid=egress --clear-groups --inh-caps=-all --bounding-set=-all --no-new-privs \
  /usr/local/bin/smokescreen --config-file "$RUN_DIR/smokescreen.yaml" \
  --listen-ip 127.0.0.1 --listen-port "$SMOKESCREEN_PORT" &
smokescreen_pid=$!

for _ in $(seq 1 50); do
  kill -0 "$smokescreen_pid" 2>/dev/null || die "smokescreen exited during start (bad config?)"
  if (exec 3<>"/dev/tcp/127.0.0.1/$SMOKESCREEN_PORT") 2>/dev/null; then
    break
  fi
  sleep 0.1
done
(exec 3<>"/dev/tcp/127.0.0.1/$SMOKESCREEN_PORT") 2>/dev/null || die "smokescreen did not listen on :$SMOKESCREEN_PORT within 5 s"
as_browserd bash -c "exec 3<>/dev/tcp/127.0.0.1/$SMOKESCREEN_PORT" || die "uid browserd cannot reach smokescreen"
log info "smokescreen listening on 127.0.0.1:$SMOKESCREEN_PORT (pid $smokescreen_pid)"

# ---------------------------------------------------------------- display

if [[ "$HEADLESS" == virtual ]]; then
  mkdir -p /tmp/.X11-unix
  chmod 1777 /tmp/.X11-unix
  as_browserd Xvfb :99 -screen 0 1920x1080x24 -nolisten tcp &
  for _ in $(seq 1 50); do
    [[ -S /tmp/.X11-unix/X99 ]] && break
    sleep 0.1
  done
  [[ -S /tmp/.X11-unix/X99 ]] || die "Xvfb did not start within 5 s"
  export DISPLAY=:99
  log info "Xvfb started on :99"
fi

cd /app
exec setpriv --reuid=browserd --regid=browserd --init-groups --inh-caps=-all --bounding-set=-all --no-new-privs \
  node /app/server.mjs
