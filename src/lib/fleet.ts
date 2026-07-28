/**
 * Fleet counts, read from the AeroCheck API at build time.
 *
 * WHY THIS EXISTS
 *
 * The /aircraft page has always been right about the fleet because it derives from the API. The
 * home page stated the same facts as hard-coded prose ("13 aircraft", "the other 12 aircraft
 * unlock with Pro") and silently drifted when per-registration aircraft landed and every tail
 * became individually selectable — leaving two pages on one site disagreeing about the fleet size,
 * with only the derived one correct.
 *
 * A build-time check would have caught that, but it only DETECTS drift; someone still has to go and
 * fix the copy. Deriving the numbers removes the possibility instead. Same reasoning as the
 * checklist `version` field in the app repo: a fact duplicated in two places, where only one of
 * them updates itself, will eventually disagree.
 *
 * Read-only. This site never writes to the API.
 */

const API = 'https://api.aerocheck.app/api/v3/aircraft/available';

interface AircraftRegistration {
  registration: string;
  modelName: string;
  aeroclub?: string;
}

interface Aircraft {
  id: string;
  registration: string;
  aeroclub?: string;
  isFree: boolean;
  registrations?: AircraftRegistration[];
}

export interface FleetCounts {
  /** One per TAIL, not per aircraft id — every registration is separately selectable in the app. */
  total: number;
  free: number;
  premium: number;
  clubs: number;
  /** False when the API could not be reached; the counts are then the fallback below. */
  live: boolean;
}

/**
 * Last-known-good counts, used only when the API is unreachable at build time.
 *
 * The site auto-deploys on push, so failing the build on a transient API outage would block an
 * unrelated copy change from shipping. The /aircraft page already degrades the same way — it
 * renders an explicit "couldn't be loaded" notice rather than failing — so tolerating it here is
 * consistent. A fallback that is silently used is the real risk, which is why it is logged loudly.
 */
const FALLBACK: Omit<FleetCounts, 'live'> = { total: 16, free: 1, premium: 15, clubs: 3 };

/** One row per tail: a multi-registration aircraft is expanded via its per-registration metadata. */
function expand(list: Aircraft[]): Aircraft[] {
  return list.flatMap((a) =>
    a.registrations?.length ? a.registrations.map((r) => ({ ...a, ...r })) : [a]
  );
}

export async function loadFleetCounts(): Promise<FleetCounts> {
  try {
    const res = await fetch(API);
    if (!res.ok) throw new Error('HTTP ' + res.status);
    const aircraft = expand((await res.json())?.data?.aircraft ?? []);
    if (!aircraft.length) throw new Error('empty roster');

    const free = aircraft.filter((a) => a.isFree).length;
    return {
      total: aircraft.length,
      free,
      premium: aircraft.length - free,
      clubs: new Set(aircraft.map((a) => a.aeroclub).filter(Boolean)).size,
      live: true,
    };
  } catch (err) {
    console.warn(
      `[fleet] Could not read the roster from the API (${err instanceof Error ? err.message : err}). ` +
        `Falling back to ${FALLBACK.total} aircraft — the page will be WRONG if the fleet has changed.`
    );
    return { ...FALLBACK, live: false };
  }
}

/**
 * Substitute fleet tokens in a copy string.
 *
 * Tokens rather than string concatenation so the YAML stays readable prose a non-developer can
 * edit: `"the other {premium} aircraft unlock with Pro"` reads as a sentence, which
 * `"the other " + n + " aircraft…"` does not.
 */
export function applyFleetTokens(text: string, counts: FleetCounts): string {
  return text
    .replace(/\{total\}/g, String(counts.total))
    .replace(/\{free\}/g, String(counts.free))
    .replace(/\{premium\}/g, String(counts.premium))
    .replace(/\{clubs\}/g, String(counts.clubs));
}

/** Recursively apply the tokens through a loaded site-copy tree (strings, arrays, objects). */
export function applyFleetTokensDeep<T>(value: T, counts: FleetCounts): T {
  if (typeof value === 'string') return applyFleetTokens(value, counts) as unknown as T;
  if (Array.isArray(value)) return value.map((v) => applyFleetTokensDeep(v, counts)) as unknown as T;
  if (value && typeof value === 'object') {
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(value as Record<string, unknown>)) {
      out[k] = applyFleetTokensDeep(v, counts);
    }
    return out as unknown as T;
  }
  return value;
}
