import fs from 'node:fs';
import path from 'node:path';
import { load } from 'js-yaml';

import type { Lang } from './langs';
export type { Lang } from './langs';
export { LANGS, LANG_NAMES, DATE_LOCALES, langBase, pathWithoutLang, pathInLang } from './langs';

export interface CTA { label: string; href: string; icon: string; }
/** A label beside a screenshot, with a line to what it names. `x` and `y` are the target's position on the
 *  screenshot, in percent; `side` says which side of it the label sits on. `where` names the place in words
 *  for the narrow layout, where the labels go under the picture without lines. */
export interface Callout { where: string; title: string; text: string; x: number; y: number; side: 'left' | 'right'; }
/** A flagship row. `shot` is shown on both devices; `iphone_shot` overrides the iPhone's. A row whose
 *  anchor or step belongs to FLY sits in the FLY band (see Landing.astro). `facts`: at most three, plain
 *  text, never chips. `note`: one calm line under them (the safety sentence by the checklists). */
export interface FlagshipItem { step: string; title: string; description: string; facts?: string[]; note?: string; shot: string; iphone_shot?: string; anchor?: string; fly?: boolean; where?: boolean; }
/** The iPhone band in FLY: the phone in portrait, then on its side. */
export interface PhoneBand { step: string; title: string; description: string; shots: [string, string]; }
/** One of the four chapters a flight has in the app. `core` marks FLY, drawn filled like the app does. */
export interface Chapter { key: string; name: string; line: string; core?: boolean; }
export interface Link { label: string; href: string; }
export interface Tier { name: string; title: string; text: string; highlight?: boolean; }
export interface Qa { q: string; a: string; }
/** One moment of the story page's flight: when (words or the flight's clock), the chapter, a line, a short
 *  paragraph and one screenshot (`story` key). */
export interface Moment { when: string; sub: string; chapter: string; fly?: boolean; title: string; text: string; shot: string; alt: string; }

export interface SiteData {
  lang: Lang;
  meta: { title: string; description: string };
  brand: string;
  nav: { features: string; story: string; aircraft: string; countries: string; manual: string; changelog: string; download: string };
  store: { alt: string; cta: string };
  theme: { to_dark: string; to_light: string };
  hero: {
    eyebrow: string; title: string; subtitle: string;
    secondary: Link; facts: string;
    shot: string; shot_alt: string;
    callouts: Callout[];
  };
  dryrun: { band: string; title: string; text: string; link: Link; shot: string; alt: string };
  chapters: { heading: string; items: Chapter[]; story: Link };
  flagship: { heading: string; items: FlagshipItem[] };
  phone: PhoneBand;
  pricing: { heading: string; tiers: Tier[]; send: string; links: Link[] };
  faq: { heading: string; items: Qa[] };
  also: { label: string; items: string[] };
  story: {
    meta: { title: string; description: string };
    eyebrow: string; title: string; subtitle: string;
    secondary: Link;
    prologue: { band: string; title: string; text: string; link: Link; shot: string; alt: string };
    moments: Moment[];
    end: { title: string; text: string; secondary: Link };
  };
  device_labels: { ipad: string; iphone: string; dots: string };
  countries: CountriesCopy;
  footer: {
    safety: string;
    made_by: string; author: string; author_url: string;
    with: string; in: string; city: string;
    privacy: string; terms: string; support: string; license: string; license_url: string;
  };
}

/** One/other forms of a phrase with a count ({n}). */
export interface Plural { one: string; other: string; }
/** The Countries page's words (src/data/{lang}.yaml, `countries`); the facts come from src/lib/coverage.ts. */
export interface CountriesCopy {
  title: string; description: string; eyebrow: string;
  ask: string; choose: string; elsewhere: string; select_label: string; option_choose: string; option_elsewhere: string;
  guessed_tz: string; guessed_lang: string; empty: string;
  lead: {
    home: string; closed: string; thin: string; knows: string; and: string;
    parts: { brief: string; brief_file: string; close: string; charts: string; patterns: string; circuits: string };
    other: string; other_none: string;
  };
  prohibited: string;
  levels: { on: string; part: string; off: string };
  chapters: { prepare: string; fly: string; close: string };
  labels: Record<string, string>;
  /** The table of every country: its groups' names, its column heads and a line saying what each column is. */
  table_groups: Record<string, string>;
  table_heads: Record<string, string>;
  table_hints: Record<string, string>;
  access: { account: string; paid: string; restricted: string; signin: string };
  text: {
    general: string; no_page: string; europe_only: string;
    border_ch: string; border: string; border_off: string; openaip: string; openaip_off: string;
    nasr: string; circuits: Plural; circuits_none: string; no_source: string; routes: Plural; routes_none: string;
    charts: Plural; charts_subscription: string; charts_eaip: string; charts_start: string; charts_none: string;
    charts_reason: Record<string, string>;
    swisstopo: string; wind_ch: string; wind: string;
    close_alert: string; close_report: string; close_call: string; close_aerodromes: string; close_activation: string;
    close_unchecked: string; close_none: string; fees: Plural; fees_none: string;
  };
  everywhere: string; everywhere_here: string; everywhere_label: string; everywhere_other: string;
  checked: string; tell: string; tell_other: string;
  near: { heading: string; briefing: string; circuits: string; charts: string; chart_links: string; cockpit: string; closed: string };
  not_on_map: string; map_label: string;
  table: { summary: string; country: string; key: string };
  home_line: { lead: string; briefing: string; circuits: string; charts: string; link: string };
  where: string;
  /** "in der Schweiz", "aux Pays-Bas": the preposition goes with the country. */
  in: Record<string, string>;
}

// Site copy lives in src/data/{lang}.yaml — edit those to change wording. Read at build time (SSG).
export function loadSite(lang: Lang): SiteData {
  const file = path.resolve(process.cwd(), 'src/data', `${lang}.yaml`);
  return load(fs.readFileSync(file, 'utf8')) as SiteData;
}

// The app's App Store page, on the Swiss storefront (the author's link). `l=` picks the page's language, which on
// that storefront is German by default; the App Store app itself opens the visitor's own storefront.
export const APP_STORE_URL = 'https://apps.apple.com/ch/app/a%C3%A9rocheck/id6757646347';
export function appStoreHref(lang: Lang): string {
  return `${APP_STORE_URL}?l=${lang}`;
}
