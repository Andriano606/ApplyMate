// Image build gate (Dockerfile final stage, runs as uid browserd). Exits non-zero when
// the installed browser, the camoufox-js patch or the launch options are unusable.
// Builds launch options exactly like server.mjs (camoufox.mjs) without launching Firefox.
//
//   node scripts/smoke.mjs <expected camoufox build, e.g. 156.0.1-beta.36>
import fs from 'node:fs';
import path from 'node:path';
import { launchOptions } from 'camoufox-js';
import {
  CAMOUFOX_BIN,
  UBO_ADDON_DIR,
  launchSettings,
  versions,
} from '../camoufox.mjs';

const expectedBuild = process.argv[2];
const failures = [];
const check = (condition, message) => {
  if (!condition) failures.push(message);
};

const { playwrightCore, camoufoxBuild } = versions();
check(
  camoufoxBuild === expectedBuild,
  `version.json says ${camoufoxBuild}, expected ${expectedBuild}`,
);
check(
  fs.existsSync(path.join(UBO_ADDON_DIR, 'manifest.json')),
  `uBlock Origin addon missing at ${UBO_ADDON_DIR}`,
);

// A secret in the parent env must never reach the browser process.
process.env.BROWSERD_TOKEN = 'smoke-secret-must-not-leak';
const settings = {
  headlessMode: 'true',
  os: 'windows',
  locale: 'uk-UA',
  proxyUrl: 'http://127.0.0.1:4750/',
};
const options = await launchOptions(
  launchSettings(settings, { humanize: true }),
);

check(
  options.executablePath === CAMOUFOX_BIN,
  `executablePath is ${options.executablePath}, expected ${CAMOUFOX_BIN}`,
);
check(options.headless === true, 'headless must be true for HEADLESS=true');
check(
  options.proxy?.server === 'http://127.0.0.1:4750',
  `proxy is ${JSON.stringify(options.proxy)}`,
);
check(
  options.firefoxUserPrefs['media.peerconnection.enabled'] === false,
  'WebRTC must be disabled',
);
check(
  !Object.values(options.env).includes(process.env.BROWSERD_TOKEN),
  'BROWSERD_TOKEN leaked into the browser env',
);
check(
  Object.keys(options.env).some((key) => key.startsWith('CAMOU_CONFIG')),
  'no CAMOU_CONFIG in the browser env',
);
check(
  fs.existsSync(path.join(UBO_ADDON_DIR, 'manifest.json')),
  'launchOptions removed or replaced the uBlock addon',
);

if (failures.length > 0) {
  for (const failure of failures) console.error(`smoke: FAIL ${failure}`);
  process.exit(1);
}
console.log(
  `smoke: OK playwright-core ${playwrightCore}, camoufox ${camoufoxBuild}`,
);
