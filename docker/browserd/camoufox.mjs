// The ONE place that turns browserd settings into camoufox-js launch options. Used by
// server.mjs (POST /leases, GET /health/deep) and scripts/smoke.mjs (image build gate),
// so the build smoke exercises exactly what production launches.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);

// camoufox-js resolves the browser from ~/.cache/camoufox (pkgman.js userCacheDir) and
// reads version.json there. The Dockerfile installs it at build time; without version.json
// camoufox-js would try to DOWNLOAD the browser at launch, which node cannot (no egress).
export const CAMOUFOX_DIR = path.join(os.homedir(), '.cache', 'camoufox');
export const CAMOUFOX_BIN = path.join(CAMOUFOX_DIR, 'camoufox-bin');
export const UBO_ADDON_DIR = path.join(CAMOUFOX_DIR, 'addons', 'UBO');

// WebRTC off (no local-IP leak, no UDP around the proxy). Localhost is routed through the
// egress proxy too (which denies it) instead of Firefox's default direct-to-loopback bypass.
export const FIREFOX_USER_PREFS = Object.freeze({
  'media.peerconnection.enabled': false,
  'network.proxy.allow_hijacking_localhost': true,
});

// Seconds of cursor travel camoufox's own humanize uses when a lease asks for it.
export const HUMANIZE_MAX_TIME = 0.6;

export function versions() {
  const playwrightCore = JSON.parse(
    fs.readFileSync(require.resolve('playwright-core/package.json'), 'utf8'),
  ).version;
  const installed = JSON.parse(
    fs.readFileSync(path.join(CAMOUFOX_DIR, 'version.json'), 'utf8'),
  );
  return {
    playwrightCore,
    camoufoxBuild: `${installed.version}-${installed.release}`,
  };
}

// Firefox gets an explicit minimal environment. camoufox-js defaults `env` to process.env,
// which would hand BROWSERD_TOKEN to every browser process.
export function browserEnv(display) {
  const env = {
    PATH: process.env.PATH ?? '/usr/local/bin:/usr/bin:/bin',
    HOME: os.homedir(),
    TZ: process.env.TZ ?? 'UTC',
    LANG: 'C.UTF-8',
  };
  if (display) env.DISPLAY = display;
  return env;
}

// settings: { headlessMode: 'true'|'virtual'|'false', os, locale, proxyUrl, display }
export function launchSettings(settings, { humanize = false } = {}) {
  return {
    headless: settings.headlessMode === 'true',
    os: settings.os,
    geoip: false,
    locale: settings.locale,
    proxy: settings.proxyUrl,
    humanize: humanize ? HUMANIZE_MAX_TIME : false,
    firefox_user_prefs: { ...FIREFOX_USER_PREFS },
    env: browserEnv(settings.headlessMode === 'true' ? null : settings.display),
  };
}
