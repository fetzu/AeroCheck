// A draft checklist file (the app's checklist JSON), drawn the way the app draws
// it: the 16 phases in flight order, each titled in capitals, headers grouping items, and every item
// as challenge · dot leader · response. Plus the speeds and crosswind limits, since a wrong figure is
// the thing proofreading is most likely to catch. Text only: nothing in the file is read as markup.
import { PHASE_KEYS } from '../../lib/intake';
import type { RequestsCopy } from '../../lib/requests-copy';
import { fill, h, languageName } from './shared';

interface Item { number?: number | null; challenge?: string; response?: string; isHeader?: boolean; }
interface Phase { title?: string; pageNumber?: number; items?: Item[]; }
interface Speed { name?: string; description?: string; value?: string | number; }
export interface ChecklistFile {
  registration?: string; modelName?: string; version?: string;
  speeds?: Speed[];
  crosswindLimits?: { takeoff?: string; landing?: string };
  phases?: Record<string, Phase>;
}

const text = (v: unknown) => (v === null || v === undefined ? '' : String(v));

/** `HB-ABC_de.json` → { registration: 'HB-ABC', language: 'de' }. */
function parseName(name: string): { registration: string; language: string } {
  const m = /^(.+)_([a-z]{2})\.json$/i.exec(name);
  return m ? { registration: m[1], language: m[2].toLowerCase() } : { registration: name, language: '' };
}

function scrollTo(target: HTMLElement): void {
  target.scrollIntoView({ block: 'start' });
  target.focus({ preventScroll: true });
}

export function renderChecklist(copy: RequestsCopy, file: { name: string; json: ChecklistFile }, index: number): HTMLElement {
  const t = copy.status;
  const json = file.json ?? {};
  const { registration, language } = parseName(file.name);
  const phases = json.phases ?? {};
  const titleOf = (key: string) => text(phases[key]?.title) || copy.phases[key] || key;
  const idOf = (key: string) => `rq-cl-${index}-${key}`;

  const nav = h('nav', { class: 'rq-cl-nav', 'aria-label': t.proofPhases },
    ...PHASE_KEYS.map((key) => h('a', {
      href: `#${idOf(key)}`,
      // A plain anchor would replace #t=… in the address, and a reload would lose the request.
      onclick: (e: Event) => {
        e.preventDefault();
        const target = document.getElementById(idOf(key));
        if (target) scrollTo(target);
      },
    }, titleOf(key))));

  const speeds = Array.isArray(json.speeds) && json.speeds.length
    ? h('div', {},
        h('h3', { class: 'rq-subtitle' }, t.proofSpeeds),
        h('table', { class: 'rq-cl-speeds' },
          h('thead', {}, h('tr', {}, ...t.proofSpeedCols.map((c) => h('th', { scope: 'col' }, c)))),
          h('tbody', {}, ...json.speeds.map((s) => h('tr', {}, h('td', {}, text(s.name)), h('td', {}, text(s.description)), h('td', {}, text(s.value)))))),
        json.crosswindLimits
          ? h('p', { class: 'rq-cl-crosswind' }, fill(t.proofCrosswind, { takeoff: text(json.crosswindLimits.takeoff) || '?', landing: text(json.crosswindLimits.landing) || '?' }))
          : null)
    : null;

  const sections = PHASE_KEYS.map((key) => {
    const phase = phases[key] ?? {};
    const items = Array.isArray(phase.items) ? phase.items : [];
    return h('section', { class: 'rq-cl-phase', id: idOf(key), tabindex: '-1', 'aria-labelledby': `${idOf(key)}-title` },
      h('div', { class: 'rq-cl-phase-head' },
        h('h3', { class: 'rq-cl-phase-title', id: `${idOf(key)}-title` }, titleOf(key)),
        typeof phase.pageNumber === 'number' ? h('span', { class: 'rq-cl-page' }, fill(t.proofPage, { n: phase.pageNumber })) : null),
      items.length
        ? h('ul', { class: 'rq-cl-items' }, ...items.map((item) => item.isHeader
            ? h('li', { class: 'rq-cl-header' }, text(item.challenge))
            : h('li', { class: 'rq-cl-item' },
                h('span', { class: 'rq-cl-ch' }, text(item.challenge)),
                h('span', { class: 'rq-cl-dots', 'aria-hidden': 'true' }),
                h('span', { class: 'sr-only' }, ': '),
                h('span', { class: 'rq-cl-re' }, text(item.response)))))
        : h('p', { class: 'rq-cl-empty' }, t.proofEmptyPhase));
  });

  const meta = [json.modelName, json.version ? fill(t.proofVersion, { v: json.version }) : ''].filter(Boolean).join(' · ');
  return h('details', { class: 'rq-cl-file', open: index === 0 },
    h('summary', {},
      `${text(json.registration) || registration}${language ? ` · ${languageName(language)}` : ''}`,
      meta ? h('span', { class: 'rq-cl-file-meta' }, meta) : null),
    h('div', { class: 'rq-cl-body' }, nav, speeds, ...sections));
}
