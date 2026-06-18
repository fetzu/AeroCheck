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

// Hero auto-cycle: advance the active screenshot across both device variants + the dots.
const hero = document.querySelector('[data-hero]');
const dots = Array.from(document.querySelectorAll<HTMLElement>('[data-dots] [data-dot]'));
if (hero) {
  const cycles = Array.from(hero.querySelectorAll<HTMLElement>('.cycle'));
  const dotsWrap = document.querySelector<HTMLElement>('[data-dots]');
  const count = dots.length || cycles[0]?.querySelectorAll('img').length || 0;
  let idx = 0;
  let timer: number | undefined;
  let paused = false;

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
  const canCycle = count > 1 && !reduceMotion;
  const stop = (): void => { if (timer !== undefined) { window.clearInterval(timer); timer = undefined; } };
  const start = (): void => {
    if (canCycle && !paused && timer === undefined) {
      timer = window.setInterval(() => { idx = (idx + 1) % count; show(idx); }, 4000);
    }
  };
  const pause = (): void => { paused = true; stop(); };
  const resume = (): void => { paused = false; start(); };

  // Pause the cycle while hovering the device or keyboard-focusing the device / dots — so a frame
  // can be inspected without any modal or lightbox.
  [hero, dotsWrap].forEach((el) => {
    el?.addEventListener('pointerenter', pause);
    el?.addEventListener('pointerleave', resume);
    el?.addEventListener('focusin', pause);
    el?.addEventListener('focusout', resume);
  });

  // Clicking a dot jumps to that frame and restarts the timer from there (no immediate auto-advance).
  dots.forEach((d, di) => d.addEventListener('click', () => { idx = di; show(idx); stop(); start(); }));

  show(0);
  start();
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
