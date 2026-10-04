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
 * TODO/REPLACE: the site key of the aerocheck.app Turnstile widget (Cloudflare dashboard › Turnstile ›
 * the widget › Site Key; its secret goes to the worker as TURNSTILE_SECRET). Public by design.
 * Empty: /send uses Cloudflare's always-pass test key on localhost, and says "not open yet" anywhere else.
 */
export const TURNSTILE_SITE_KEY = '';

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

/** The checklist's own languages, offered as boxes; any other goes through the list below them. */
export const COMMON_LANGUAGES = ['en', 'fr', 'de', 'it'] as const;
export const OTHER_LANGUAGES = ['es', 'pt', 'nl', 'da', 'sv', 'no', 'fi', 'pl', 'cs', 'sk', 'sl', 'hr', 'hu', 'ro', 'el', 'tr'] as const;

/** The checklist file's phase keys, in flight order, as the checklist files have them. */
export const PHASE_KEYS = [
  'preflight', 'beforeEngineStart', 'engineStart', 'afterEngineStart', 'taxi', 'runup',
  'beforeDeparture', 'lineUp', 'climb', 'cruise', 'descent', 'approach', 'landing',
  'afterLanding', 'shutdown', 'hangar',
] as const;

/** A request's way to `live`; `need-info`, `declined` and `duplicate` branch off it. */
export const STATUS_PATH = ['received', 'accepted', 'converting', 'proofreading', 'testflight', 'live'] as const;
