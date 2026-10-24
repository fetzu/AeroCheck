import { createHash } from 'node:crypto';
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { DEFAULT_LANG, type Lang } from './langs';
import { appVersion } from './version';

export interface Shot { ipad: string; iphone: string; label: string; }

// Every image is a full screen, the iPad in PORTRAIT (1112×1600) as the Cockpit is flown on a
// kneeboard, the iPhone in portrait (800×1739) — except `landscape`, the iPhone on its side
// (1600×736). All captured deterministically via the DEBUG scene injector; see SCREENSHOTS.md.
// Each language shows its own (6.5.0): English under v6/<device>/, French and German under v6/<lang>/<device>/.
// A shot a language doesn't have falls back to the English one.

// The app version the whole set was captured from, or checked against when a release changed none of
// its screens (6.3.0). Bump it with every recapture: a build warns while the latest release is a newer
// minor version than this (`warnIfShotsAreOld`).
export const CAPTURED_FROM = '6.5.0';

// Each URL carries a hash of the image (`?v=1a2b3c4d`), read at build time, so a recaptured image is
// a new URL. The file names never change, and Cloudflare lets a browser keep an image for 4 hours:
// after the 6.2.0 recapture, a visitor who had seen the page that day kept seeing the 6.0 images.
const PUBLIC = join(process.cwd(), 'public');
function versioned(path: string): string {
  try {
    const hash = createHash('sha1').update(readFileSync(join(PUBLIC, path))).digest('hex').slice(0, 8);
    return `${path}?v=${hash}`;
  } catch {
    console.warn(`[shots] ${path} is missing from public/.`);
    return path;
  }
}
function v6(device: 'ipad' | 'iphone', key: string, lang: Lang): string {
  const own = `/assets/screenshot/v6/${lang}/${device}/${key}.jpg`;
  if (lang !== DEFAULT_LANG && existsSync(join(PUBLIC, own))) return versioned(own);
  return versioned(`/assets/screenshot/v6/${device}/${key}.jpg`);
}

// Each shot's key and label; `ipad: false` for the iPhone on its side, which has no iPad counterpart.
const KEYS: Record<string, { label: string; ipad?: false }> = {
  cockpit:    { label: 'The Cockpit in cruise' },
  cockpitmap: { label: 'The Cockpit on its map' },
  // 6.2: Plan › Map close in on LSZQ, its traffic circuit and arrival sectors from open flightmaps.
  circuits:   { label: 'Traffic circuits on the map' },
  vspeeds:    { label: 'V-SPEEDS' },
  today:      { label: 'Today, with the day’s flight' },
  flight:     { label: 'A followed flight' },
  prepare:    { label: 'Preparing a flight' },
  closeout:   { label: 'Closing out a flight' },
  route:      { label: 'The route editor' },
  log:        { label: 'A flight in the logbook' },
  // 6.4.0: a guided dry run on its final, the coach's card over the card that chooses the landing.
  dryrun:     { label: 'A dry run on the ground' },
  landscape:  { label: 'The iPhone on its side', ipad: false },
};

const byLang = new Map<Lang, Record<string, Shot>>();
function shotsIn(lang: Lang): Record<string, Shot> {
  let shots = byLang.get(lang);
  if (!shots) {
    shots = Object.fromEntries(Object.entries(KEYS).map(([key, { label, ipad }]) =>
      [key, { ipad: ipad === false ? '' : v6('ipad', key, lang), iphone: v6('iphone', key, lang), label }]));
    byLang.set(lang, shots);
  }
  return shots;
}

export const SHOTS: Record<string, Shot> = shotsIn(DEFAULT_LANG);

// The story page (/flight): one real flight, Bressaucourt to Samedan in F-HVXA, replayed from its own GPS track on
// the simulator and captured as it went (6.4.0 site). iPad only, in the order the page tells it.
export const STORY: Record<string, string> = Object.fromEntries(
  ['route', 'prepare', 'lineup', 'automark', 'alps', 'approach', 'closeout', 'log']
    .map((key) => [key, versioned(`/assets/screenshot/v6/story/${key}.jpg`)]),
);

// The guard rail: put a key in PLACEHOLDERS if its image is ever a stand-in, and `shot()` warns on
// every build until it is recaptured.
const PLACEHOLDERS = new Set<string>();

const warned = new Set<string>();
export function shot(key: string, lang: Lang = DEFAULT_LANG): Shot {
  if (PLACEHOLDERS.has(key) && !warned.has(key)) {
    warned.add(key);
    console.warn(`[shots] PLACEHOLDER image in use for "${key}" — capture the scene before shipping.`);
  }
  const found = shotsIn(lang)[key];
  if (!found) throw new Error(`[shots] unknown shot key "${key}"`);
  return found;
}

// The other guard rail: the set was captured from `CAPTURED_FROM`, and a release of a newer minor
// version (6.3 after 6.2) may have changed what it shows. Warns once a build; never fails it.
let checkedAge = false;
export async function warnIfShotsAreOld(): Promise<void> {
  if (checkedAge) return;
  checkedAge = true;
  const minor = (v: string) => v.split('.').slice(0, 2).map(Number);
  const [capMajor, capMinor] = minor(CAPTURED_FROM);
  const [major, minorNow] = minor(await appVersion());
  if (major > capMajor || (major === capMajor && minorNow > capMinor)) {
    console.warn(`[shots] The screenshots were captured from ${CAPTURED_FROM}; the latest release is ` +
      `${await appVersion()}. Check them against it and recapture what changed (SCREENSHOTS.md).`);
  }
}
