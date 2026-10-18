// Client behaviour: mobile nav and scroll reveal, both Reduce-Motion aware. The hero no longer cycles its
// screens (6.4.0 site: one Cockpit, explained, and nothing that moves by itself).
const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

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
