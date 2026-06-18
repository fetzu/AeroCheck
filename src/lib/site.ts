import fs from 'node:fs';
import path from 'node:path';
import yaml from 'js-yaml';

export type Lang = 'en' | 'fr';

export interface CTA { label: string; href: string; icon: string; }
export interface FlagshipItem { step: string; title: string; description: string; chips: string[]; shot: string; }
export interface SupportingItem { title: string; description: string; icon: string; }
export interface EcoItem { label: string; icon: string; }

export interface SiteData {
  lang: Lang;
  meta: { title: string; description: string };
  brand: string;
  nav: { features: string; aircraft: string; manual: string; changelog: string; download: string };
  hero: {
    eyebrow: string; title: string; subtitle: string;
    primary: CTA; secondary: CTA;
    cycle_caption: string; cycle: string[];
  };
  flagship: { heading: string; items: FlagshipItem[] };
  supporting: { heading: string; items: SupportingItem[] };
  ecosystem: EcoItem[];
  device_toggle: { ipad: string; iphone: string };
  footer: {
    made_by: string; author: string; author_url: string;
    with: string; in: string; city: string;
    privacy: string; license: string; license_url: string;
  };
}

// Site copy lives in src/data/{lang}.yaml — edit those to change wording. Read at build time (SSG).
export function loadSite(lang: Lang): SiteData {
  const file = path.resolve(process.cwd(), 'src/data', `${lang}.yaml`);
  return yaml.load(fs.readFileSync(file, 'utf8')) as SiteData;
}
