export interface Shot { ipad: string; iphone: string; label: string; }

// PLACEHOLDER screenshots — current v4 full-frame captures. These are intentionally temporary:
// flagship + hero shots will be replaced with purpose-captured REGIONS (see the capture playbook
// we'll build together). Swap the paths here once the region captures exist; nothing else changes.
export const SHOTS: Record<string, Shot> = {
  hud:      { ipad: '/assets/screenshot/iPad/02.jpg', iphone: '/assets/screenshot/iPhone/02.jpg', label: 'In-flight HUD' },
  nav:      { ipad: '/assets/screenshot/iPad/03.jpg', iphone: '/assets/screenshot/iPhone/03.jpg', label: 'Navigation' },
  planning: { ipad: '/assets/screenshot/iPad/04.jpg', iphone: '/assets/screenshot/iPhone/04.jpg', label: 'Flight planning' },
  airspace: { ipad: '/assets/screenshot/iPad/04.jpg', iphone: '/assets/screenshot/iPhone/04.jpg', label: 'Airspace' },
  log:      { ipad: '/assets/screenshot/iPad/05.jpg', iphone: '/assets/screenshot/iPhone/05.jpg', label: 'Flight log' },
  home:     { ipad: '/assets/screenshot/iPad/01.jpg', iphone: '/assets/screenshot/iPhone/01.jpg', label: 'Home' },
};

export function shot(key: string): Shot {
  return SHOTS[key] ?? SHOTS.hud;
}
