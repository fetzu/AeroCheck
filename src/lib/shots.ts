export interface Shot { ipad: string; iphone: string; label: string; }

// v5 purpose-captured shots (2026-06-18). Flagship feature rows use focused REGION crops
// (planning / hud / nav / airspace); the hero carousel + 'log'/'home' use full-device hero shots.
// All captured deterministically via the DEBUG marketing scene injector — see the capture playbook.
// iPad regions are mixed aspect (1.44–1.58) shown at native ratio in feature rows; iPhone are full
// portrait (~0.46). The hero carousel cover-crops to a fixed aspect, so any of these fit there too.
export const SHOTS: Record<string, Shot> = {
  hud:      { ipad: '/assets/screenshot/v5/ipad/hud.jpg',      iphone: '/assets/screenshot/v5/iphone/hud.jpg',      label: 'In-flight HUD' },
  nav:      { ipad: '/assets/screenshot/v5/ipad/nav.jpg',      iphone: '/assets/screenshot/v5/iphone/nav.jpg',      label: 'Navigation' },
  planning: { ipad: '/assets/screenshot/v5/ipad/planning.jpg', iphone: '/assets/screenshot/v5/iphone/planning.jpg', label: 'Flight planning' },
  airspace: { ipad: '/assets/screenshot/v5/ipad/airspace.jpg', iphone: '/assets/screenshot/v5/iphone/airspace.jpg', label: 'Airspace' },
  log:      { ipad: '/assets/screenshot/v5/ipad/log.jpg',      iphone: '/assets/screenshot/v5/iphone/log.jpg',      label: 'Flight log' },
  home:     { ipad: '/assets/screenshot/v5/ipad/home.jpg',     iphone: '/assets/screenshot/v5/iphone/home.jpg',     label: 'Home' },
};

export function shot(key: string): Shot {
  return SHOTS[key] ?? SHOTS.hud;
}
