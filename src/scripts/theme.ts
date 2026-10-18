// Light or dark (6.4.0 site). The page follows the visitor's setting; the nav's switch forces the other theme by
// setting data-theme on <html>, and a tap back to the setting's theme clears it, so the page follows the setting
// again. The choice is kept in this browser only (localStorage); Base.astro's head re-applies it before the first
// paint.
type Theme = 'light' | 'dark';
const KEY = 'aerocheck-theme';
const COLORS: Record<Theme, string> = { light: '#F4F2EC', dark: '#141419' };

const root = document.documentElement;
const media = window.matchMedia('(prefers-color-scheme: dark)');
const system = (): Theme => (media.matches ? 'dark' : 'light');
const forced = (): Theme | null => {
  const t = root.dataset.theme;
  return t === 'light' || t === 'dark' ? t : null;
};
const effective = (): Theme => forced() ?? system();

// Two copies of the switch: the bar's (phones) and the menu's (wider screens).
const buttons = document.querySelectorAll<HTMLButtonElement>('[data-theme-toggle]');

function sync(): void {
  const now = effective();
  buttons.forEach((b) => b.setAttribute('aria-label', (now === 'dark' ? b.dataset.labelLight : b.dataset.labelDark) ?? ''));
  // The browser's bar: both theme-color tags take the forced theme's colour, or their own when following.
  const f = forced();
  document.querySelectorAll<HTMLMetaElement>('meta[name="theme-color"]').forEach((m) => {
    m.content = COLORS[f ?? (m.media.includes('dark') ? 'dark' : 'light')];
  });
}

function force(theme: Theme | null): void {
  if (theme) root.dataset.theme = theme;
  else delete root.dataset.theme;
  try {
    if (theme) localStorage.setItem(KEY, theme);
    else localStorage.removeItem(KEY);
  } catch { /* private window or blocked storage: the choice lasts for this page only */ }
  sync();
}

buttons.forEach((b) => {
  b.hidden = false;
  b.addEventListener('click', () => {
    const next: Theme = effective() === 'dark' ? 'light' : 'dark';
    force(next === system() ? null : next);
  });
});
// A forced theme lasts while it differs from the setting: once the setting matches it (changed while the page is
// open, or since the last visit), the page follows the setting again.
media.addEventListener('change', () => (forced() === system() ? force(null) : sync()));
if (forced() === system()) force(null);
else sync();
