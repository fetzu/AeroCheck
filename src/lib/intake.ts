/**
 * Aircraft requests: the constants the request pages (/send, /request, /confirm) share with the
 * intake worker (AeroCheck-server, workers/intake, whose docs describe its routes); the worker enforces every limit below again, these only spare the sender a round trip.
 *
 * Imported by the pages (build time) and by their scripts (in the browser): nothing Node-only here.
 */

/** The intake worker. `PUBLIC_INTAKE_URL` at build time points the pages at another one (a local
 *  `wrangler dev`, whose ALLOWED_ORIGIN must then be the local site); production never sets it. */
export const INTAKE_URL: string = (import.meta.env.PUBLIC_INTAKE_URL || 'https://intake.aerocheck.app').replace(/\/+$/, '');

/**
 * The site key of the aerocheck.app Turnstile widget (Cloudflare dashboard › Turnstile › "AéroCheck
 * requests" › Site Key; its secret goes to the worker as TURNSTILE_SECRET). Public by design. The
 * widget allows aerocheck.app only, so a local preview uses the test key below instead. Empty: /send
 * says "not open yet" anywhere but on localhost.
 */
export const TURNSTILE_SITE_KEY = '0x4AAAAAAFOiLRlFcqqwezEh';

/** Cloudflare's documented test key: always passes, visibly. Only ever used on localhost. */
export const TURNSTILE_TEST_KEY = '1x00000000000000000000AA';
export const TURNSTILE_SCRIPT = 'https://challenges.cloudflare.com/turnstile/v0/api.js';

/** Section 5's limits. Megabytes are decimal, as Finder counts them: stricter than 10 × 1024², so
 *  whichever the worker uses, it never refuses a file that passed here. */
export const MAX_REGISTRATIONS = 10;
export const MAX_FILES = 4;
export const MAX_FILE_BYTES = 10_000_000;
export const MAX_TOTAL_BYTES = 25_000_000;
export const NOTES_MAX = 1000;
export const MESSAGE_MAX = 2000;
/** The club's message on /confirm has no limit in the contract: the notes' one, to be safe. */
export const CLUB_MESSAGE_MAX = 1000;

/** After normalising (uppercase, no spaces), as the worker accepts it. */
export const REGISTRATION_PATTERN = /^[A-Z0-9]{1,2}-?[A-Z0-9]{1,5}$/;

/** The file types the worker accepts, with what their first bytes must be (it checks them again). */
export const FILE_TYPES = {
  'application/pdf': { label: 'PDF', extensions: ['pdf'] },
  'image/jpeg': { label: 'JPEG', extensions: ['jpg', 'jpeg'] },
  'image/png': { label: 'PNG', extensions: ['png'] },
  'image/heic': { label: 'HEIC', extensions: ['heic', 'heif'] },
} as const;
export type FileType = keyof typeof FILE_TYPES;
export const FILE_ACCEPT = '.pdf,.jpg,.jpeg,.png,.heic,.heif,application/pdf,image/jpeg,image/png,image/heic,image/heif';

/** The checklist's own languages, offered as boxes (Switzerland's four and English). Any other is
 *  typed: the worker keeps a language as sent ("Japanese", "it-CH"), so the field suggests and
 *  never restricts. */
export const COMMON_LANGUAGES = ['en', 'fr', 'de', 'it'] as const;
/** The field's suggestions: every ISO 639-1 code, named in the page's language at build time (a
 *  code the runtime cannot name is left out). */
export const SUGGESTED_LANGUAGES = (
  'aa ab af ak am an ar as av ay az ba be bg bi bm bn bo br bs ca ce ch co cr cs cu cv cy da de dv dz ee el en eo es et eu ' +
  'fa ff fi fj fo fr fy ga gd gl gn gu gv ha he hi ho hr ht hu hy hz ia id ie ig ii ik io is it iu ja jv ka kg ki kj kk kl km ' +
  'kn ko kr ks ku kv kw ky la lb lg li ln lo lt lu lv mg mh mi mk ml mn mr ms mt my na nb nd ne ng nl nn no nr nv ny oc oj om ' +
  'or os pa pi pl ps pt qu rm rn ro ru rw sa sc sd se sg si sk sl sm sn so sq sr ss st su sv sw ta te tg th ti tk tl tn to tr ' +
  'ts tt tw ty ug uk ur uz ve vi vo wa wo xh yi yo za zh zu'
).split(' ');
/** The worker's rule for one language: letters, spaces and dashes, 2 to 35 characters; 5 at most. */
export const LANGUAGE_PATTERN = /^\p{L}[\p{L} -]*$/u;
export const LANGUAGE_MIN = 2;
export const LANGUAGE_MAX = 35;
export const MAX_LANGUAGES = 5;

/** The checklist file's phase keys, in flight order, as the checklist files have them. */
export const PHASE_KEYS = [
  'preflight', 'beforeEngineStart', 'engineStart', 'afterEngineStart', 'taxi', 'runup',
  'beforeDeparture', 'lineUp', 'climb', 'cruise', 'descent', 'approach', 'landing',
  'afterLanding', 'shutdown', 'hangar',
] as const;

/** A request's way to `live`; `need-info`, `declined` and `duplicate` branch off it. */
export const STATUS_PATH = ['received', 'accepted', 'converting', 'proofreading', 'testflight', 'live'] as const;
