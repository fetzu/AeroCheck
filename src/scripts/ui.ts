// Client behaviour: global device toggle, hero auto-cycle, scroll reveal. All Reduce-Motion aware.
const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

type Device = 'ipad' | 'iphone';

function applyDevice(d: Device): void {
  document.body.dataset.device = d;
  document.querySelectorAll<HTMLButtonElement>('.device-toggle button').forEach((b) => {
    b.setAttribute('aria-pressed', String(b.dataset.device === d));
  });
}

const saved = localStorage.getItem('ac-device') as Device | null;
applyDevice(saved === 'iphone' ? 'iphone' : 'ipad');
document.querySelectorAll<HTMLButtonElement>('.device-toggle button').forEach((b) => {
  b.addEventListener('click', () => {
    const d = (b.dataset.device as Device) || 'ipad';
    applyDevice(d);
    localStorage.setItem('ac-device', d);
  });
});

// Mobile nav menu (hamburger) toggle.
const navToggle = document.querySelector<HTMLButtonElement>('[data-nav-toggle]');
const navMenu = document.getElementById('nav-menu');
if (navToggle && navMenu) {
  const setNav = (open: boolean): void => {
    navMenu.classList.toggle('is-open', open);
    navToggle.setAttribute('aria-expanded', String(open));
  };
  navToggle.addEventListener('click', () => setNav(!navMenu.classList.contains('is-open')));
  navMenu.querySelectorAll('a').forEach((a) => a.addEventListener('click', () => setNav(false)));
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape') setNav(false); });
  document.addEventListener('click', (e) => {
    const t = e.target as Node;
    if (navMenu.classList.contains('is-open') && !navMenu.contains(t) && !navToggle.contains(t)) setNav(false);
  });
}

// Hero auto-cycle: advance the active screenshot across both device variants + the dots.
// Play/pause is driven by visibility + interaction so it behaves on touch as well as mouse:
//   • IntersectionObserver — only cycles while the hero is on screen, and RESUMES when scrolled back
//     (fixes touch devices where a scroll-"hover" used to stop it forever).
//   • Hover-pause is attached ONLY on true-hover devices via `(hover: hover)` — touch fires
//     pointerenter but not reliably pointerleave, which would otherwise leave it stuck paused.
//   • Page Visibility pauses when the tab is hidden; keyboard focus pauses for inspection.
const hero = document.querySelector('[data-hero]');
const dots = Array.from(document.querySelectorAll<HTMLElement>('[data-dots] [data-dot]'));
if (hero) {
  const cycles = Array.from(hero.querySelectorAll<HTMLElement>('.cycle'));
  const dotsWrap = document.querySelector<HTMLElement>('[data-dots]');
  const count = dots.length || cycles[0]?.querySelectorAll('img').length || 0;
  const canCycle = count > 1 && !reduceMotion;

  let idx = 0;
  let timer: number | undefined;
  let inView = true;     // set by IntersectionObserver when supported
  let hovering = false;  // only ever true on hover-capable (mouse/pen) devices
  let focused = false;   // keyboard focus within the hero or dots

  const show = (i: number): void => {
    cycles.forEach((c) => {
      c.querySelectorAll<HTMLImageElement>('img').forEach((img) => {
        img.classList.toggle('is-active', Number(img.dataset.i) === i);
      });
    });
    dots.forEach((d, di) => {
      d.classList.toggle('is-active', di === i);
      d.setAttribute('aria-pressed', String(di === i));
    });
  };

  const shouldPlay = (): boolean => canCycle && inView && !hovering && !focused && !document.hidden;
  const sync = (): void => {
    if (shouldPlay()) {
      if (timer === undefined) timer = window.setInterval(() => { idx = (idx + 1) % count; show(idx); }, 4000);
    } else if (timer !== undefined) {
      window.clearInterval(timer); timer = undefined;
    }
  };

  // Hover-pause: only on devices that truly hover (mouse/pen). Skipped on touch entirely.
  if (window.matchMedia('(hover: hover)').matches) {
    [hero, dotsWrap].forEach((el) => {
      el?.addEventListener('pointerenter', () => { hovering = true; sync(); });
      el?.addEventListener('pointerleave', () => { hovering = false; sync(); });
    });
  }
  // Keyboard focus pauses (so focused users can read / operate the dots).
  [hero, dotsWrap].forEach((el) => {
    el?.addEventListener('focusin', () => { focused = true; sync(); });
    el?.addEventListener('focusout', () => { focused = false; sync(); });
  });
  // Pause when the tab is backgrounded; resume when it returns.
  document.addEventListener('visibilitychange', sync);
  // Only cycle while the hero is on screen — and resume when it scrolls back into view.
  if ('IntersectionObserver' in window) {
    inView = false;
    new IntersectionObserver((entries) => { inView = entries[0]?.isIntersecting ?? false; sync(); },
      { threshold: 0.4 }).observe(hero);
  }

  // Clicking a dot jumps to that frame and restarts the interval from there.
  dots.forEach((d, di) => d.addEventListener('click', () => {
    idx = di; show(idx);
    if (timer !== undefined) { window.clearInterval(timer); timer = undefined; }
    sync();
  }));

  show(0);
  sync();
}

// Scroll reveal.
const revealEls = document.querySelectorAll<HTMLElement>('.reveal');
if (reduceMotion || !('IntersectionObserver' in window)) {
  revealEls.forEach((el) => el.classList.add('is-visible'));
} else {
  const io = new IntersectionObserver((entries) => {
    entries.forEach((e) => {
      if (e.isIntersecting) { e.target.classList.add('is-visible'); io.unobserve(e.target); }
    });
  }, { rootMargin: '0px 0px -10% 0px', threshold: 0.1 });
  revealEls.forEach((el) => io.observe(el));
}
