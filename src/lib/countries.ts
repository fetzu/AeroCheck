// The Countries page's content, built at build time from the server's coverage file (coverage.ts) and the page's words
// (src/data/{lang}.yaml, `countries`): per country its name, the phrase that shows it ("in der Schweiz"), a one-line
// summary, a row per feature by chapter (a level and its words), its neighbours on the map, and the table of every
// country. Everything is rendered into the page; the browser only picks which country shows (src/scripts/countries.ts).
import type { CountriesCopy, Lang, Plural } from './site';
import { DATE_LOCALES } from './langs';
import { BRIEFING, type Coverage, type CountryCoverage, type Level, type Publisher } from './coverage';
import map from '../data/europe-map.json';

export interface MapCountry { d: string; c: [number, number]; b: [number, number, number, number]; dot: boolean; n: string[]; }
export const MAP = map as unknown as { w: number; h: number; countries: Record<string, MapCountry> };

export type FeatureId = (typeof BRIEFING)[number] | 'border' | 'openaip' | 'circuits' | 'routes' | 'charts' | 'swisstopo'
  | 'wind' | 'close' | 'fees';
export const CHAPTERS: { id: 'prepare' | 'fly' | 'close'; features: FeatureId[] }[] = [
  { id: 'prepare', features: [...BRIEFING, 'border'] },
  { id: 'fly', features: ['openaip', 'circuits', 'routes', 'charts', 'swisstopo', 'wind'] },
  { id: 'close', features: ['close', 'fees'] },
];
const ALL: FeatureId[] = CHAPTERS.flatMap((c) => c.features);
// The table of every country, its columns grouped by what a pilot does with them rather than by the app's chapters:
// the briefing's links, the flight plan filed and closed side by side, the border, what the map draws, the fees (the
// author, 25 Oct 2026). Left out: the swisstopo charts, which only Switzerland has, and the surface wind, model winds
// everywhere but Switzerland's stations; each country's own panel still lists them. A group of one is a column.
export const TABLE_GROUPS: { id: 'briefing' | 'flightplan' | 'border' | 'map' | 'fees'; features: FeatureId[] }[] = [
  { id: 'briefing', features: ['weather', 'notam', 'airspace', 'forecast'] },
  { id: 'flightplan', features: ['filing', 'close'] },
  { id: 'border', features: ['border'] },
  { id: 'map', features: ['openaip', 'circuits', 'routes', 'charts'] },
  { id: 'fees', features: ['fees'] },
];
const TABLE: FeatureId[] = TABLE_GROUPS.flatMap((g) => g.features);
// The first column of each group, which draws the group's left edge down the table.
const GROUP_START = new Set(TABLE_GROUPS.map((g) => g.features[0]));

export interface Row { id: FeatureId; label: string; level: Level; html: string; }
export interface Group { id: 'prepare' | 'fly' | 'close'; name: string; rows: Row[]; }
export interface Neighbour { cc: string; name: string; line: string; }
export interface CountryView {
  cc: string; name: string; phrase: string; lead: string; prohibited?: string;
  groups: Group[]; near: Neighbour[]; checked?: string; tell: string; onMap: boolean;
}
export interface MatrixRow { cc: string; name: string; cells: { id: FeatureId; level: Level; n?: number; start: boolean }[]; }
export interface TableColumn { id: FeatureId; head: string; hint: string; start: boolean; }
/** A group of the table's header: its name over its columns, or, for a group of one, just that column. */
export interface TableGroup { name?: string; columns: TableColumn[]; }
export interface CountriesView { countries: CountryView[]; matrix: MatrixRow[]; table: TableGroup[]; }

const esc = (s: string) => s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]!);
const fill = (template: string, vars: Record<string, string | number>) =>
  template.replace(/\{(\w+)\}/g, (whole, key) => (key in vars ? String(vars[key]) : whole));
const cap = (s: string) => s.charAt(0).toUpperCase() + s.slice(1);

export function countryNamer(lang: Lang): (cc: string) => string {
  let names: Intl.DisplayNames | undefined;
  try { names = new Intl.DisplayNames([DATE_LOCALES[lang], lang], { type: 'region' }); } catch { /* old ICU */ }
  return (cc) => names?.of(cc) ?? cc;
}

export function buildCountries(coverage: Coverage, lang: Lang, t: CountriesCopy): CountriesView {
  const name = countryNamer(lang);
  const number = (n: number) => n.toLocaleString(DATE_LOCALES[lang]);
  const plural = (p: Plural, n: number, vars: Record<string, string | number> = {}) =>
    fill(n === 1 ? p.one : p.other, { ...vars, n: `<span class="n">${number(n)}</span>` });
  const chip = (word: string) => `<span class="acc">${esc(word)}</span>`;
  const publishers = (list: Publisher[] = []) =>
    list.map((p) => esc(p.names?.[lang] ?? p.name) + (p.access !== 'open' && t.access[p.access] ? chip(t.access[p.access]) : '')).join(', ');
  const phrase = (cc: string) => {
    if (t.in[cc]) return t.in[cc];
    console.warn(`[countries] No "${lang}" phrase for ${cc} in src/data/${lang}.yaml (countries.in): using its bare name.`);
    return name(cc);
  };

  function row(id: FeatureId, c: CountryCoverage, cc: string): { level: Level; html: string } {
    switch (id) {
      case 'weather': case 'notam': case 'airspace': case 'forecast': case 'filing': {
        const b = c[id];
        if (!b) return { level: 'off', html: esc(t.text.europe_only) };
        if (b.level === 'off') return { level: 'off', html: esc(t.text.no_page) };
        if (b.level === 'part') return { level: 'part', html: fill(esc(t.text.general), { publishers: publishers(b.publishers) }) };
        return { level: 'on', html: publishers(b.publishers) };
      }
      case 'border':
        return c.border ? { level: 'on', html: esc(cc === 'CH' ? t.text.border_ch : t.text.border) } : { level: 'off', html: esc(t.text.border_off) };
      case 'openaip':
        return c.openaip ? { level: 'on', html: esc(t.text.openaip) } : { level: 'off', html: esc(t.text.openaip_off) };
      case 'circuits': {
        const k = c.circuits;
        if (k?.source === 'nasr') return { level: 'on', html: fill(esc(t.text.nasr), { n: `<span class="n">${number(k.count)}</span>`, altitudes: `<span class="n">${number(k.altitudes ?? 0)}</span>` }) };
        if (k && k.count) return { level: k.level, html: plural(t.text.circuits, k.count) };
        if (k) return { level: 'off', html: fill(esc(t.text.circuits_none), { points: number(c.points ?? 0) }) };
        return { level: 'off', html: esc(t.text.no_source) };
      }
      case 'routes': {
        const r = c.routes;
        if (r && r.count) return { level: r.level, html: plural(t.text.routes, r.count) };
        return { level: 'off', html: esc(r ? t.text.routes_none : t.text.no_source) };
      }
      case 'charts': {
        const ch = c.charts;
        if (ch?.kind === 'every' && ch.count) return { level: 'on', html: plural(t.text.charts, ch.count) };
        if (ch?.kind === 'subscription') return { level: 'part', html: esc(t.text.charts_subscription) + chip(t.access.paid) };
        if (ch?.kind === 'eaip') return { level: 'part', html: esc(t.text.charts_eaip) };
        if (ch?.kind === 'start') return { level: 'part', html: esc(t.text.charts_start) + (ch.signin ? chip(t.access.signin) : '') };
        return { level: 'off', html: esc((ch?.reason && t.text.charts_reason[ch.reason]) || t.text.charts_none) };
      }
      case 'swisstopo':
        return c.swisstopo ? { level: 'on', html: esc(t.text.swisstopo) } : { level: 'off', html: '' };
      case 'wind':
        return c.wind === 'meteoswiss' ? { level: 'on', html: esc(t.text.wind_ch) } : { level: 'part', html: esc(t.text.wind) };
      case 'close': {
        const k = c.close;
        if (!k) return { level: 'off', html: esc(t.text.close_none) };
        if (k.level !== 'on') return { level: 'part', html: esc(t.text.close_unchecked) };
        const rule = k.alertMinutes ? fill(t.text.close_alert, { m: k.alertMinutes })
          : k.reportMinutes ? fill(t.text.close_report, { m: k.reportMinutes }) : t.text.close_call;
        const who = k.units?.length ? esc(k.units.join(', ')) : k.aerodromes ? fill(esc(t.text.close_aerodromes), { n: `<span class="n">${number(k.aerodromes)}</span>` }) : '';
        return { level: 'on', html: esc(rule) + (who ? '; ' + who : '') + (k.activation ? '. ' + esc(t.text.close_activation) : '') };
      }
      case 'fees':
        return c.fees ? { level: 'on', html: plural(t.text.fees, c.fees.count) } : { level: 'off', html: esc(t.text.fees_none) };
    }
  }

  function lead(cc: string, c: CountryCoverage): string {
    if (cc === 'CH') return t.lead.home;
    if (c.prohibited) return t.lead.closed;
    const usable = (k: (typeof BRIEFING)[number]) => c[k]?.level === 'on';
    const parts: string[] = [];
    if (usable('weather') || usable('notam')) parts.push(c.filing?.level === 'on' ? t.lead.parts.brief_file : t.lead.parts.brief);
    if (c.close?.level === 'on') parts.push(t.lead.parts.close);
    if (c.charts?.kind === 'every') parts.push(t.lead.parts.charts);
    if (c.circuits?.source === 'nasr') parts.push(t.lead.parts.patterns);
    else if (c.circuits?.level === 'on') parts.push(fill(t.lead.parts.circuits, { n: number(c.circuits.count) }));
    const In = cap(phrase(cc));
    if (!parts.length) return fill(t.lead.thin, { In });
    const list = parts.length < 2 ? parts[0] : parts.slice(0, -1).join(', ') + t.lead.and + parts[parts.length - 1];
    return fill(t.lead.knows, { In, list });
  }

  function nearLine(c: CountryCoverage): string {
    if (c.prohibited) return t.near.closed;
    const bits: string[] = [];
    if (BRIEFING.some((k) => c[k]?.level === 'on' || c[k]?.level === 'part')) bits.push(t.near.briefing);
    if (c.circuits?.count) bits.push(fill(t.near.circuits, { n: number(c.circuits.count) }));
    if (c.charts?.kind === 'every' && c.charts.count) bits.push(fill(t.near.charts, { n: number(c.charts.count) }));
    else if (c.charts?.level === 'part') bits.push(t.near.chart_links);
    return bits.length ? bits.join(' · ') : t.near.cockpit;
  }

  const codes = Object.keys(coverage.countries).sort((a, b) => name(a).localeCompare(name(b), lang));
  const countries: CountryView[] = codes.map((cc) => {
    const c = coverage.countries[cc];
    // A closed country has no briefing to list: its red line says it all
    const groups: Group[] = CHAPTERS.map(({ id, features }) => ({
      id,
      name: t.chapters[id],
      rows: features
        .filter((f) => !(f === 'swisstopo' && !c.swisstopo) && !(f === 'border' && !c.border))
        .filter((f) => !(c.prohibited && (BRIEFING as readonly string[]).includes(f)))
        .map((f) => ({ id: f, label: t.labels[f], ...row(f, c, cc) })),
    })).filter((g) => g.rows.length);
    const near = (MAP.countries[cc]?.n ?? [])
      .filter((n) => coverage.countries[n])
      .sort((a, b) => name(a).localeCompare(name(b), lang))
      .map((n) => ({ cc: n, name: name(n), line: nearLine(coverage.countries[n]) }));
    const checked = c.reviewed
      ? fill(t.checked, { date: new Date(c.reviewed).toLocaleDateString(DATE_LOCALES[lang], { day: 'numeric', month: 'short', year: 'numeric' }) })
      : undefined;
    return {
      cc, name: name(cc), phrase: phrase(cc), lead: lead(cc, c),
      prohibited: c.prohibited ? fill(t.prohibited, { directive: c.prohibited }) : undefined,
      groups, near, checked, tell: fill(t.tell, { in: phrase(cc) }), onMap: !!MAP.countries[cc],
    };
  });

  const matrix: MatrixRow[] = codes.map((cc) => {
    const c = coverage.countries[cc];
    return {
      cc, name: name(cc),
      cells: TABLE.map((id) => {
        const { level } = row(id, c, cc);
        const n = level === 'off' ? undefined
          : id === 'circuits' ? c.circuits?.count : id === 'routes' ? c.routes?.count
          : id === 'charts' ? c.charts?.count : id === 'fees' ? c.fees?.count : undefined;
        return { id, level, n, start: GROUP_START.has(id) };
      }),
    };
  });

  const column = (id: FeatureId): TableColumn => ({ id, head: t.table_heads[id], hint: t.table_hints[id], start: GROUP_START.has(id) });
  const table: TableGroup[] = TABLE_GROUPS.map((g) => ({
    name: g.features.length > 1 ? t.table_groups[g.id] : undefined,
    columns: g.features.map(column),
  }));
  return { countries, matrix, table };
}
