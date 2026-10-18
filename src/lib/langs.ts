// The site's languages, in the order of the nav's switch (EN · DE · FR, 6.5.0). English sits at the root; every other
// language under its own prefix (/de/…, /fr/…). A new language is its code here, its name and formats below, its
// src/data/<code>.yaml, its pages under src/pages/<code>/ and its entries in the components' copy tables, which are
// typed by `Lang` so the build says which ones are missing. No Node import: the request pages' scripts use it too.
export const LANGS = ['en', 'de', 'fr'] as const;
export type Lang = (typeof LANGS)[number];
export const DEFAULT_LANG: Lang = 'en';

/** Each language in its own name, for the switch's accessible names and the request pages' language links. */
export const LANG_NAMES: Record<Lang, string> = { en: 'English', de: 'Deutsch', fr: 'Français' };

/** The locale a page's dates and numbers are written in: Switzerland's for German and French, British English. */
export const DATE_LOCALES: Record<Lang, string> = { en: 'en-GB', de: 'de-CH', fr: 'fr-CH' };

export function isLang(value: string | null | undefined): value is Lang {
  return (LANGS as readonly string[]).includes(value ?? '');
}

/** The prefix of a language's pages: '' for English, '/de' for German. */
export function langBase(lang: Lang): string {
  return lang === DEFAULT_LANG ? '' : `/${lang}`;
}

/** A page's path without its language prefix: /de/flight → /flight, /fr → /. */
export function pathWithoutLang(pathname: string): string {
  const prefixes = LANGS.filter((l) => l !== DEFAULT_LANG).join('|');
  return pathname.replace(new RegExp(`^/(?:${prefixes})(?=/|$)`), '') || '/';
}

/** The same page in another language: ('/flight', 'de') → /de/flight, ('/', 'fr') → /fr. */
export function pathInLang(path: string, lang: Lang): string {
  const base = langBase(lang);
  return path === '/' ? base || '/' : `${base}${path}`;
}
