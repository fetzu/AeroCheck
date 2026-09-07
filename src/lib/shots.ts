export interface Shot { ipad: string; iphone: string; label: string; }

// Recaptured 2026-09-07 against review/v5-cumulative-fixes, after the button-label and Home layout
// pass — every image below is a FULL-DEVICE screen, iPad landscape (1600×1112) and iPhone portrait
// (800×1739). (An older comment here described some of them as region crops; they were already full
// screens by then.) All captured deterministically via the DEBUG scene injector — see SCREENSHOTS.md.
// The hero carousel cover-crops to a fixed aspect, so any of these fit there too.
export const SHOTS: Record<string, Shot> = {
  hud:      { ipad: '/assets/screenshot/v5/ipad/hud.jpg',      iphone: '/assets/screenshot/v5/iphone/hud.jpg',      label: 'In-flight HUD' },
  // Hero carousel uses the FULL iPad HUD screen; the cropped `hud` region is reserved for the Fly
  // feature-row highlight. iPhone is full-screen in both cases, so it reuses the same image.
  hudhero:  { ipad: '/assets/screenshot/v5/ipad/hud-hero.jpg', iphone: '/assets/screenshot/v5/iphone/hud.jpg',      label: 'In-flight HUD' },
  nav:      { ipad: '/assets/screenshot/v5/ipad/nav.jpg',      iphone: '/assets/screenshot/v5/iphone/nav.jpg',      label: 'Navigation' },
  planning: { ipad: '/assets/screenshot/v5/ipad/planning.jpg', iphone: '/assets/screenshot/v5/iphone/planning.jpg', label: 'Flight planning' },
  airspace: { ipad: '/assets/screenshot/v5/ipad/airspace.jpg', iphone: '/assets/screenshot/v5/iphone/airspace.jpg', label: 'Airspace' },
  log:      { ipad: '/assets/screenshot/v5/ipad/log.jpg',      iphone: '/assets/screenshot/v5/iphone/log.jpg',      label: 'Flight log' },
  home:     { ipad: '/assets/screenshot/v5/ipad/home.jpg',     iphone: '/assets/screenshot/v5/iphone/home.jpg',     label: 'Home' },
};

// The 5.0.0 flight-thread scenes, captured the same way and at the same time as the rest.
// PLACEHOLDERS stays as the guard rail: put a key back in it if its image ever goes stand-in again,
// and `shot()` will warn on every build until it is recaptured.
const PLACEHOLDERS = new Set<string>();
SHOTS.flight     = { ipad: '/assets/screenshot/v5/ipad/flight.jpg',     iphone: '/assets/screenshot/v5/iphone/flight.jpg',     label: 'A followed flight' };
SHOTS.prepare    = { ipad: '/assets/screenshot/v5/ipad/prepare.jpg',    iphone: '/assets/screenshot/v5/iphone/prepare.jpg',    label: 'Preparing a flight' };
SHOTS.closeout   = { ipad: '/assets/screenshot/v5/ipad/closeout.jpg',   iphone: '/assets/screenshot/v5/iphone/closeout.jpg',   label: 'Closing out a flight' };
SHOTS.homeflight = { ipad: '/assets/screenshot/v5/ipad/homeflight.jpg', iphone: '/assets/screenshot/v5/iphone/homeflight.jpg', label: "Today's flight on Home" };

const warned = new Set<string>();
export function shot(key: string): Shot {
  if (PLACEHOLDERS.has(key) && !warned.has(key)) {
    warned.add(key);
    console.warn(`[shots] PLACEHOLDER image in use for "${key}" — capture the 5.0 scene before shipping.`);
  }
  return SHOTS[key] ?? SHOTS.hud;
}
