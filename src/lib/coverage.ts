/**
 * What the app has in each country, read from the AeroCheck server at build time.
 *
 * WHY THIS EXISTS
 *
 * The Countries page (/countries, decided 22 Oct 2026) says, per country, which briefing pages, circuits, chart links
 * and landing-fee links the app has. Those facts change every week: the server's data job checks every link, open
 * flightmaps adds circuits, a chart index breaks. Typed into the copy they would drift, as the manual's "21 countries"
 * already had when South Africa's chart index broke. So the server's weekly job sums them up in one small file
 * (/data/coverage/v1/coverage.json: levels, counts and the publishers' names, never a link or a number) and the site
 * reads it when it builds, like the fleet and the landing-fee counts (fleet.ts).
 *
 * The file is client-gated (`X-AeroCheck-Client`); the build sends AEROCHECK_CLIENT when the CI has it. Without it,
 * or when the API can't be reached, the build uses the copy committed in src/data/coverage.snapshot.json, loudly.
 *
 * Only what the App Store version has (the author's q5): a feature that came with a version not yet released is left
 * out until the release rebuilds the site (deploy-website-on-release.yml on main).
 *
 * Read-only. This site never writes to the API.
 */

import fs from 'node:fs';
import path from 'node:path';
import { appVersion } from './version';

export type Level = 'on' | 'part' | 'off';
export type Access = 'open' | 'account' | 'paid' | 'restricted';
export interface Publisher { name: string; access: Access; names?: Record<string, string>; }
export interface Category { level: Level; publishers?: Publisher[]; }
export interface Close {
  level: Level;
  alertMinutes?: number;
  reportMinutes?: number;
  /** Whose number it is ("DSNA ARO"), never the number. */
  units?: string[];
  /** How many aerodromes have their own (Spain). */
  aerodromes?: number;
  ats?: 'sera' | 'controlled' | 'atsu' | 'report';
  activation?: boolean;
}
export interface Counted { level: Level; count: number; }
export interface Circuits extends Counted { source: 'ofm' | 'nasr'; altitudes?: number; }
export interface Charts {
  level: Level;
  kind?: 'every' | 'subscription' | 'eaip' | 'start';
  count?: number;
  signin?: boolean;
  reason?: 'terms' | 'homepage' | 'sold' | 'unreadable';
}
export interface CountryCoverage {
  weather?: Category; notam?: Category; airspace?: Category; forecast?: Category; filing?: Category;
  close?: Close;
  /** The directive that forbids flying there ("EASA SD-2021-02"). */
  prohibited?: string;
  reviewed?: string;
  circuits?: Circuits;
  routes?: Counted;
  points?: number;
  charts?: Charts;
  fees?: Counted;
  border?: { level: Level };
  openaip?: boolean;
  swisstopo?: boolean;
  wind?: 'meteoswiss';
}
export interface Coverage {
  v: number;
  generated: string;
  countries: Record<string, CountryCoverage>;
  /** False when the API could not be read and the committed copy stands in. */
  live?: boolean;
}

export const BRIEFING = ['weather', 'notam', 'airspace', 'forecast', 'filing'] as const;

const API = 'https://api.aerocheck.app/data/coverage/v1/coverage.json';
const SNAPSHOT = path.resolve(process.cwd(), 'src/data/coverage.snapshot.json');

let cached: Promise<Coverage> | undefined;

/** The server's file as it is, memoized per build. */
export function loadCoverage(): Promise<Coverage> {
  cached ??= read();
  return cached;
}

function usable(document: unknown): document is Coverage {
  const c = document as Coverage | null;
  return !!c && c.v === 1 && !!c.countries && Object.keys(c.countries).length > 0;
}

async function read(): Promise<Coverage> {
  const client = process.env.AEROCHECK_CLIENT;
  try {
    const res = await fetch(API, { headers: client ? { 'X-AeroCheck-Client': client } : {}, signal: AbortSignal.timeout(20_000) });
    if (!res.ok) throw new Error('HTTP ' + res.status + (res.status === 403 && !client ? ' (AEROCHECK_CLIENT not set)' : ''));
    const document = await res.json();
    if (!usable(document)) throw new Error('not a coverage file');
    return { ...document, live: true };
  } catch (err) {
    const snapshot = JSON.parse(fs.readFileSync(SNAPSHOT, 'utf8')) as Coverage;
    console.warn(
      `[coverage] Could not read ${API} (${err instanceof Error ? err.message : err}). ` +
        `Falling back to src/data/coverage.snapshot.json of ${snapshot.generated}: the Countries page will be WRONG if ` +
        `the data has changed since.`
    );
    return { ...snapshot, live: false };
  }
}

/** "6.5.0" ≥ "6.4.3". */
export function atLeast(version: string, wanted: string): boolean {
  const a = version.split('.').map((n) => parseInt(n, 10) || 0);
  const b = wanted.split('.').map((n) => parseInt(n, 10) || 0);
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    if ((a[i] ?? 0) !== (b[i] ?? 0)) return (a[i] ?? 0) > (b[i] ?? 0);
  }
  return true;
}

/**
 * The coverage as the released app has it. 6.5.0 brought the briefing pages and the closing rule beyond Switzerland
 * (Switzerland's came earlier), the US traffic patterns and the chart links of Australia, New Zealand and the US.
 */
export function released(coverage: Coverage, version: string): Coverage {
  if (atLeast(version, '6.5.0')) return coverage;
  const countries: Record<string, CountryCoverage> = {};
  for (const [cc, facts] of Object.entries(coverage.countries)) {
    const c: CountryCoverage = { ...facts };
    if (cc !== 'CH') {
      // The app had no page for them yet ("No page yet", not "Europe only")
      for (const key of BRIEFING) if (c[key]) c[key] = { level: 'off' };
      delete c.close; delete c.prohibited; delete c.reviewed;
    }
    if (c.circuits?.source === 'nasr') delete c.circuits;
    if (['AU', 'NZ', 'US'].includes(cc)) c.charts = { level: 'off' };
    countries[cc] = c;
  }
  return { ...coverage, countries };
}

/** AEROCHECK_PREVIEW_VERSION builds the site as if that app version were out, to check a release's pages before it ships. */
export async function loadReleasedCoverage(): Promise<Coverage> {
  return released(await loadCoverage(), process.env.AEROCHECK_PREVIEW_VERSION || (await appVersion()));
}

/** The counts the copy quotes ({briefingCountries}, {ofmCountries}, …): derived, never typed. */
export interface CoverageCounts {
  briefingCountries: number;
  ofmCountries: number;
  circuitCountries: number;
  chartCountries: number;
  /** The chart countries the manual doesn't name (DFS, the SIA, skyguide, Austro Control and the FAA it does). */
  chartOthers: number;
}

export function coverageCounts(coverage: Coverage): CoverageCounts {
  const all = Object.entries(coverage.countries);
  const has = (l?: Level) => l === 'on' || l === 'part';
  const charts = all.filter(([, c]) => has(c.charts?.level)).map(([cc]) => cc);
  return {
    briefingCountries: all.filter(([, c]) => BRIEFING.some((k) => has(c[k]?.level))).length,
    ofmCountries: all.filter(([, c]) => c.routes !== undefined).length,
    circuitCountries: all.filter(([, c]) => has(c.circuits?.level)).length,
    chartCountries: charts.length,
    chartOthers: charts.filter((cc) => !['DE', 'FR', 'CH', 'AT', 'US'].includes(cc)).length,
  };
}
