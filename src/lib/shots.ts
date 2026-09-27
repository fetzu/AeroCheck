export interface Shot { ipad: string; iphone: string; label: string; }

// 6.0: every image is a full screen, the iPad in PORTRAIT (1112×1600) as the Cockpit is flown on a
// kneeboard, the iPhone in portrait (800×1739) — except `landscape`, the iPhone on its side
// (1600×736). All captured deterministically via the DEBUG scene injector; see SCREENSHOTS.md.
// These are the proposal-era captures: the whole set is recaptured from the merged 6.0 build.
const v6 = (device: 'ipad' | 'iphone', key: string) => `/assets/screenshot/v6/${device}/${key}.jpg`;
const both = (key: string, label: string): Shot => ({ ipad: v6('ipad', key), iphone: v6('iphone', key), label });

export const SHOTS: Record<string, Shot> = {
  cockpit:    both('cockpit', 'The Cockpit in cruise'),
  cockpitmap: both('cockpitmap', 'The Cockpit on its map'),
  vspeeds:    both('vspeeds', 'V-SPEEDS'),
  today:      both('today', 'Today, with the day’s flight'),
  flight:     both('flight', 'A followed flight'),
  prepare:    both('prepare', 'Preparing a flight'),
  closeout:   both('closeout', 'Closing out a flight'),
  route:      both('route', 'The route editor'),
  log:        both('log', 'A flight in the logbook'),
  // The iPhone on its side; no iPad counterpart.
  landscape:  { ipad: '', iphone: v6('iphone', 'landscape'), label: 'The iPhone on its side' },
};

// The guard rail: put a key in PLACEHOLDERS if its image is ever a stand-in, and `shot()` warns on
// every build until it is recaptured.
const PLACEHOLDERS = new Set<string>();

const warned = new Set<string>();
export function shot(key: string): Shot {
  if (PLACEHOLDERS.has(key) && !warned.has(key)) {
    warned.add(key);
    console.warn(`[shots] PLACEHOLDER image in use for "${key}" — capture the scene before shipping.`);
  }
  const found = SHOTS[key];
  if (!found) throw new Error(`[shots] unknown shot key "${key}"`);
  return found;
}
