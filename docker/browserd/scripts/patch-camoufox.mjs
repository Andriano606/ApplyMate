// Idempotent validator patch for camoufox-js 0.10.2 (same patch as the Stealth Render
// Studio "Cloudflare" config this image keeps parity with).
//
// camoufox-js 0.10.2 validates the generated fingerprint config against the browser's
// properties.json and throws `UnknownProperty` for keys the Camoufox 156 build dropped
// (e.g. navigator.appCodeName). The patch turns that throw into `continue`, so unknown
// keys are skipped instead of aborting every launch.
//
// Runs as the npm `postinstall` hook. Exits 1 when the pattern is gone AND the marker is
// absent: that means camoufox-js changed under the pin and the image must not ship.
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';

const PATTERN =
  /throw new UnknownProperty\(`Unknown property \$\{key\} in config`\);/;
const MARKER = 'CAMOUFOX_PATCHED';
const REPLACEMENT = `continue; /* ${MARKER}: skip unknown props */`;

const require = createRequire(import.meta.url);
const file = path.join(
  path.dirname(require.resolve('camoufox-js')),
  'utils.js',
);
const source = fs.readFileSync(file, 'utf8');

if (source.includes(MARKER)) {
  console.log(`patch-camoufox: already patched (${file})`);
} else if (PATTERN.test(source)) {
  fs.writeFileSync(file, source.replace(PATTERN, REPLACEMENT));
  console.log(`patch-camoufox: patched ${file}`);
} else {
  console.error(
    `patch-camoufox: validator pattern not found and no ${MARKER} marker in ${file}`,
  );
  process.exit(1);
}
