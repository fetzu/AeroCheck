// The Countries page in the browser: which country shows. A link that names one (/countries#FR) wins; otherwise the
// device's time zone, then the browser's languages, guess it. All of it in the browser: nothing is sent, stored or
// looked up (the author's decision of 22 Oct 2026), and a line under the phrase says what the guess came from. A tap on
// the phrase, the map, a neighbour or the table changes the country, and the address follows (#FR) so it can be shared.
type Box = { b: [number, number, number, number]; c: [number, number] };
interface Data {
  lang: string;
  tz: Record<string, string>;
  boxes: Record<string, Box>;
  names: Record<string, string>;
  near: Record<string, string[]>;
  phrases: Record<string, string>;
  copy: { choose: string; elsewhere: string; guessed_tz: string; guessed_lang: string; other: string; other_none: string };
}

const source = document.getElementById('cty-data');
if (source) start(JSON.parse(source.textContent || '{}') as Data);

function start(data: Data): void {
  document.documentElement.classList.add('cty-ready');
  const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  const fill = (template: string, vars: Record<string, string>) => template.replace(/\{(\w+)\}/g, (w, k) => vars[k] ?? w);
  const sel = document.getElementById('cty-sel') as HTMLSelectElement;
  const pick = document.getElementById('cty-pick')!;
  const pickText = document.getElementById('cty-pick-text')!;
  const guessLine = document.getElementById('cty-guess')!;
  const otherLead = document.getElementById('cty-other-lead')!;
  const svg = document.querySelector<SVGSVGElement>('#cty-map svg')!;
  const label = document.getElementById('cty-label') as unknown as SVGTextElement;
  const table = document.getElementById('every-country') as HTMLDetailsElement | null;
  const head = document.querySelector('.c-head');
  const blocks = Array.from(document.querySelectorAll<HTMLElement>('[data-for]'));
  const rows = Array.from(document.querySelectorAll<HTMLElement>('[data-row]'));
  const lands = Array.from(svg.querySelectorAll<SVGElement>('[data-cc]'));
  const known = (cc: string) => cc in data.names;
  const europe = Object.keys(data.names).filter((cc) => data.boxes[cc] && cc !== 'GL');
  let regionName: ((cc: string) => string) | undefined;
  try {
    const names = new Intl.DisplayNames([data.lang], { type: 'region' });
    regionName = (cc) => names.of(cc) ?? cc;
  } catch { /* an old browser: the generic line */ }
  // Folded once the script runs; open without one, where the table is the page
  if (table) table.open = false;

  // ---------- The map: frames the country and its neighbours ----------
  let view = svg.viewBox.baseVal ? [svg.viewBox.baseVal.x, svg.viewBox.baseVal.y, svg.viewBox.baseVal.width, svg.viewBox.baseVal.height] : [0, 0, 1000, 825];
  let animation = 0;
  const marks = () => {
    for (const dot of Array.from(svg.querySelectorAll('circle'))) dot.setAttribute('r', (view[2] / 110).toFixed(2));
    label.setAttribute('font-size', (view[2] / 24).toFixed(2));
    label.setAttribute('stroke-width', (view[2] / 160).toFixed(2));
  };
  function frame(codes: string[]): void {
    let [x0, y0, x1, y1] = [Infinity, Infinity, -Infinity, -Infinity];
    for (const cc of codes) {
      const b = data.boxes[cc]?.b;
      if (!b) continue;
      x0 = Math.min(x0, b[0]); y0 = Math.min(y0, b[1]); x1 = Math.max(x1, b[2]); y1 = Math.max(y1, b[3]);
    }
    if (!Number.isFinite(x0)) return;
    let w = Math.max(x1 - x0, 170) * 1.15;
    let h = Math.max(y1 - y0, 130) * 1.15;
    if (w / h > 4 / 3) h = (w * 3) / 4; else w = (h * 4) / 3;
    const target = [(x0 + x1) / 2 - w / 2, (y0 + y1) / 2 - h / 2, w, h];
    const from = view.slice();
    const t0 = performance.now();
    cancelAnimationFrame(animation);
    const step = (now: number) => {
      const k = reduceMotion ? 1 : Math.min(1, (now - t0) / 450);
      const e = 1 - Math.pow(1 - k, 3);
      view = from.map((v, i) => v + (target[i] - v) * e);
      svg.setAttribute('viewBox', view.map((v) => v.toFixed(1)).join(' '));
      marks();
      if (k < 1) animation = requestAnimationFrame(step);
    };
    if (reduceMotion) step(t0); else animation = requestAnimationFrame(step);
  }

  // ---------- Showing a country ----------
  // `cc`: a country of the page, 'XX' for elsewhere, '' for none chosen. `how`: what the guess came from.
  function show(cc: string, how = '', other = ''): void {
    const country = known(cc) ? cc : cc ? 'XX' : '';
    pickText.textContent = country === 'XX' ? data.copy.elsewhere : country ? data.phrases[country] : data.copy.choose;
    pick.classList.toggle('none', !country);
    sel.value = country;
    guessLine.textContent = how;
    guessLine.hidden = !how;
    otherLead.textContent = other ? fill(data.copy.other, { name: other }) : data.copy.other_none;
    const near = country && country !== 'XX' ? data.near[country] ?? [] : [];
    const onMap = !!data.boxes[country];
    for (const b of blocks) {
      const f = b.dataset.for;
      b.classList.toggle('on', f === country || (f === 'offmap' && !!country && !onMap));
    }
    for (const land of lands) {
      const c = land.dataset.cc!;
      land.classList.toggle('here', c === country);
      land.classList.toggle('near', near.includes(c));
    }
    if (onMap) {
      label.textContent = data.names[country];
      label.setAttribute('x', String(data.boxes[country].c[0]));
      label.setAttribute('y', String(data.boxes[country].c[1]));
    } else label.textContent = '';
    frame(onMap ? [country, ...near] : europe);
    for (const row of rows) row.classList.toggle('sel', row.dataset.row === country);
  }

  function choose(cc: string, scroll = false): void {
    show(cc);
    history.replaceState(null, '', known(cc) ? `#${cc}` : location.pathname + location.search);
    if (scroll) head?.scrollIntoView({ behavior: reduceMotion ? 'auto' : 'smooth', block: 'start' });
  }

  // ---------- The guess ----------
  function guess(): void {
    const hash = location.hash.slice(1).toUpperCase();
    if (known(hash)) return show(hash);
    let zone = '';
    try { zone = Intl.DateTimeFormat().resolvedOptions().timeZone || ''; } catch { /* none */ }
    const byZone = data.tz[zone];
    if (byZone) return show(byZone, fill(data.copy.guessed_tz, { tz: zone }), known(byZone) ? '' : regionName?.(byZone) ?? '');
    for (const language of navigator.languages || [navigator.language]) {
      const region = /-([A-Za-z]{2})(?:-|$)/.exec(language)?.[1]?.toUpperCase();
      if (region) return show(region, fill(data.copy.guessed_lang, { lang: language }), known(region) ? '' : regionName?.(region) ?? '');
    }
    show('');
  }

  sel.addEventListener('change', () => choose(sel.value));
  document.querySelector('.countries')?.addEventListener('click', (event) => {
    const target = (event.target as Element).closest<HTMLElement | SVGElement>('[data-cc]');
    if (!target) return;
    event.preventDefault();
    choose(target.dataset.cc!, !!target.closest('.matrix'));
  });
  window.addEventListener('hashchange', () => {
    const hash = location.hash.slice(1).toUpperCase();
    if (known(hash)) show(hash);
  });
  guess();
}
