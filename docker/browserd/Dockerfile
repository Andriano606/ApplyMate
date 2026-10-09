# syntax=docker/dockerfile:1
#
# browserd: Camoufox lease daemon (see .ai/docs/browser.md).
#
# Image tag = the pinned triple plus the browserd revision, single source for docker-compose.yml, CI and Kamal:
#   andriano606/apply_mate_browserd:156.0.1-beta.36-pw1.63.0-r2
#   (camoufox CAMOUFOX_VERSION-CAMOUFOX_RELEASE, playwright-core from package.json, BROWSERD_REVISION below)
# Bump all places (ARGs below, package.json/package-lock.json, the tag) together. ANY change under docker/browserd/
# (server.mjs, leases.mjs, entrypoint, ...) bumps BROWSERD_REVISION: a rebuilt image under an unchanged tag is never
# pulled again by Kamal or compose, so the old server would keep running.
#
# The build FAILS (non-zero) when: TARGETARCH is not amd64/arm64, a download's sha256
# does not match, camoufox-bin is missing, `camoufox-bin --version` does not report
# CAMOUFOX_VERSION, the camoufox-js validator patch does not apply, the lease unit tests
# fail, smokescreen does not run, or scripts/smoke.mjs rejects the launch options.

ARG NODE_IMAGE=node:22-trixie-slim

# ---------------------------------------------------------------- smokescreen (egress proxy)
# Cross-compiled on the build platform (static, CGO off) so multi-arch builds stay fast.
FROM --platform=$BUILDPLATFORM golang:1.26-bookworm AS smokescreen
ARG TARGETARCH
# stripe/smokescreen master as of 2026-10-07 ("Update documentation (#345)").
# go.mod at this commit requires go >= 1.26, hence golang:1.26.
ARG SMOKESCREEN_COMMIT=d533c7aa3eb3ffd2a3fe275dc3bb01dcd2dfa4ea
RUN git clone --quiet https://github.com/stripe/smokescreen.git /src \
 && git -C /src checkout --quiet --detach "${SMOKESCREEN_COMMIT}" \
 && cd /src \
 && CGO_ENABLED=0 GOOS=linux GOARCH="${TARGETARCH}" \
    go build -mod=vendor -trimpath -ldflags='-s -w' -o /out/smokescreen . \
 && test -x /out/smokescreen

# ---------------------------------------------------------------- node deps + unit tests
FROM ${NODE_IMAGE} AS deps
RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 make g++ \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY package.json package-lock.json ./
COPY scripts/patch-camoufox.mjs scripts/
# postinstall = scripts/patch-camoufox.mjs (exits 1 when the patch cannot be applied)
RUN npm ci --omit=dev && npm cache clean --force
COPY leases.mjs lease_proxy.mjs ./
COPY test/ test/
RUN npm test

# ---------------------------------------------------------------- Camoufox + uBlock Origin
# Downloads are architecture-independent work, so this stage runs on the build platform.
# bsdtar, not unzip: the zip's font bundles have UTF-8 names that Info-ZIP unzip mangles
# (and reports with exit code 1).
FROM --platform=$BUILDPLATFORM debian:trixie-slim AS camoufox
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]
ARG TARGETARCH
ARG CAMOUFOX_VERSION=156.0.1
ARG CAMOUFOX_RELEASE=beta.36
ENV LC_ALL=C.UTF-8
# sha256 of the GitHub release assets camoufox-<version>-<release>-lin.<arch>.zip
ARG CAMOUFOX_SHA256_AMD64=72637885ee67c93466ad377831c647192f8f08fb5c6fd9279de1320b49dd2b53
ARG CAMOUFOX_SHA256_ARM64=8b5fd083721c807ee2a752265683482477105052fa0e21739388b527ae067c15
# camoufox-js loads uBlock Origin as a default addon and would download "latest" from
# addons.mozilla.org at every launch if it were missing (node has no egress). Pinned here.
ARG UBO_URL=https://addons.mozilla.org/firefox/downloads/file/5034826/ublock_origin-1.75.0.xpi
ARG UBO_SHA256=5b74415860456370644bd80f16125e865b0e6c356bb5dfcfb84069967eaa5287
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl libarchive-tools \
 && rm -rf /var/lib/apt/lists/*
RUN case "${TARGETARCH}" in \
      amd64) arch=x86_64; sha="${CAMOUFOX_SHA256_AMD64}" ;; \
      arm64) arch=arm64;  sha="${CAMOUFOX_SHA256_ARM64}" ;; \
      *) echo "unsupported TARGETARCH '${TARGETARCH}' (amd64|arm64)" >&2; exit 1 ;; \
    esac \
 && zip="camoufox-${CAMOUFOX_VERSION}-${CAMOUFOX_RELEASE}-lin.${arch}.zip" \
 && curl -fsSL --retry 3 -o /tmp/camoufox.zip \
      "https://github.com/daijro/camoufox/releases/download/v${CAMOUFOX_VERSION}-${CAMOUFOX_RELEASE}/${zip}" \
 && echo "${sha}  /tmp/camoufox.zip" | sha256sum -c - \
 && mkdir -p /opt/camoufox \
 && bsdtar -xf /tmp/camoufox.zip -C /opt/camoufox \
 && rm /tmp/camoufox.zip \
 && test -x /opt/camoufox/camoufox-bin \
 && printf '{"version":"%s","release":"%s"}' "${CAMOUFOX_VERSION}" "${CAMOUFOX_RELEASE}" >/opt/camoufox/version.json
RUN curl -fsSL --retry 3 -o /tmp/ubo.xpi "${UBO_URL}" \
 && echo "${UBO_SHA256}  /tmp/ubo.xpi" | sha256sum -c - \
 && mkdir -p /opt/camoufox/addons/UBO \
 && bsdtar -xf /tmp/ubo.xpi -C /opt/camoufox/addons/UBO \
 && rm /tmp/ubo.xpi \
 && test -f /opt/camoufox/addons/UBO/manifest.json \
 && chmod -R a+rX,go-w /opt/camoufox

# ---------------------------------------------------------------- runtime
FROM ${NODE_IMAGE}
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]
ARG CAMOUFOX_VERSION=156.0.1
ARG CAMOUFOX_RELEASE=beta.36
# Revision of the browserd code itself (the image tag's last part). r2: per-lease ttl_s (POST /leases).
ARG BROWSERD_REVISION=r2
LABEL org.opencontainers.image.version="${CAMOUFOX_VERSION}-${CAMOUFOX_RELEASE}-${BROWSERD_REVISION}"

# Firefox runtime libraries (trixie t64 names), software GL for WebGL, Xvfb for
# HEADLESS=virtual, iptables + util-linux (setpriv) for the egress isolation, curl for
# the container healthcheck, tzdata for TZ.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      libgtk-3-0t64 libdbus-glib-1-2 libxt6t64 libasound2t64 libx11-xcb1 libxcomposite1 \
      libxcursor1 libxdamage1 libxfixes3 libxi6 libxrandr2 libxrender1 libxss1 libxtst6 \
      libegl1 libgl1 libgl1-mesa-dri libgbm1 libpci3 fontconfig xvfb \
      iptables util-linux ca-certificates curl tzdata \
 && rm -rf /var/lib/apt/lists/*

# browserd: node + every Firefox it launches (firewalled to the proxy).
# egress: smokescreen, the only uid with outbound network.
RUN groupadd --gid 1001 browserd \
 && useradd --uid 1001 --gid 1001 --home-dir /home/browserd --create-home --shell /usr/sbin/nologin browserd \
 && groupadd --gid 1002 egress \
 && useradd --uid 1002 --gid 1002 --home-dir /nonexistent --no-create-home --shell /usr/sbin/nologin egress

# geoip is off (node has no egress), so the browser timezone comes from TZ.
ENV HOME=/home/browserd \
    TZ=Europe/Kyiv \
    NODE_ENV=production

# Browser install is root-owned and read-only for browserd (camoufox-js only reads it).
COPY --from=camoufox /opt/camoufox /home/browserd/.cache/camoufox
RUN chown browserd:browserd /home/browserd/.cache
COPY --from=smokescreen /out/smokescreen /usr/local/bin/smokescreen

WORKDIR /app
COPY --from=deps /app/node_modules node_modules
COPY package.json leases.mjs lease_proxy.mjs camoufox.mjs server.mjs smokescreen.yaml.tmpl entrypoint.sh ./
COPY scripts/ scripts/
RUN chmod 0755 entrypoint.sh

# Build smoke: every check must pass or the image is not produced.
RUN test -x /home/browserd/.cache/camoufox/camoufox-bin \
 && /usr/local/bin/smokescreen --help >/dev/null \
 && version="$(setpriv --reuid=browserd --regid=browserd --init-groups \
      /home/browserd/.cache/camoufox/camoufox-bin --version 2>&1)" \
 && echo "camoufox-bin --version: ${version}" \
 && grep -q "${CAMOUFOX_VERSION}" <<<"${version}" \
 && setpriv --reuid=browserd --regid=browserd --init-groups \
      node scripts/smoke.mjs "${CAMOUFOX_VERSION}-${CAMOUFOX_RELEASE}"

EXPOSE 9300 9301-9303
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD curl -fsS "http://127.0.0.1:${PORT:-9300}/health" >/dev/null || exit 1
ENTRYPOINT ["/app/entrypoint.sh"]
