// What the request pages' scripts share: talking to the intake worker, its errors, and building DOM
// from what it answers. Every value the worker returns is set as text (never as HTML): a status
// message or a checklist item is whatever someone typed.
import { INTAKE_URL } from '../../lib/intake';
import type { RequestsCopy } from '../../lib/requests-copy';

export type Lang = 'en' | 'fr';
export const lang: Lang = document.documentElement.lang === 'fr' ? 'fr' : 'en';

/** The page's copy, handed over by its component as JSON (src/lib/requests-copy.ts). */
export function readCopy(): RequestsCopy {
  const el = document.getElementById('rq-copy');
  return JSON.parse(el?.textContent || '{}') as RequestsCopy;
}

export function fill(text: string, values: Record<string, string | number>): string {
  return text.replace(/\{(\w+)\}/g, (all, key: string) => (key in values ? String(values[key]) : all));
}

// ---------------------------------------------------------------------------------------------
// The worker
// ---------------------------------------------------------------------------------------------

/**
 * An answer that wasn't a success: the worker's `{ error, field?, … }` (`data` keeps the whole body,
 * for the codes that say more: `registrations` with `known_registration`, `ticket` or `state` with
 * `wrong_state`), or `network` when nothing came back.
 */
export class IntakeError extends Error {
  constructor(public code: string, public status: number, public field?: string, public data: Record<string, unknown> = {}) {
    super(code);
  }
}

/** The worker's error body, from a fetch Response or an XHR's text. */
export function errorFromBody(status: number, body: unknown): IntakeError {
  const b = body && typeof body === 'object' ? body as Record<string, unknown> : {};
  const code = typeof b.error === 'string' ? b.error : `http_${status}`;
  return new IntakeError(code, status, typeof b.field === 'string' ? b.field : undefined, b);
}

async function errorFrom(res: Response): Promise<IntakeError> {
  let body: unknown = null;
  try { body = await res.json(); } catch { /* not JSON: the status says enough */ }
  return errorFromBody(res.status, body);
}

/** A JSON call to the worker. No cookies, no referrer: the token in the path is all it needs. */
export async function call<T>(path: string, init: { method?: string; body?: unknown } = {}): Promise<T> {
  let res: Response;
  try {
    res = await fetch(INTAKE_URL + path, {
      method: init.method ?? 'GET',
      headers: init.body === undefined ? undefined : { 'Content-Type': 'application/json' },
      body: init.body === undefined ? undefined : JSON.stringify(init.body),
      mode: 'cors',
      credentials: 'omit',
      cache: 'no-store',
      referrerPolicy: 'no-referrer',
    });
  } catch {
    throw new IntakeError('network', 0);
  }
  if (!res.ok) throw await errorFrom(res);
  if (res.status === 204) return undefined as T;
  try {
    return (await res.json()) as T;
  } catch {
    throw new IntakeError('internal', res.status);
  }
}

/** A worker URL from an answer (`/v1/uploads/…`), refused unless it stays on the worker's own host. */
export function intakeUrl(pathOrUrl: string): URL {
  const base = new URL(INTAKE_URL);
  const url = new URL(pathOrUrl, base);
  if (url.origin !== base.origin) throw new IntakeError('internal', 0);
  return url;
}

/** Every code the intake worker answers with (its docs, "Error codes"); each has its sentence in the copy. */
const KNOWN_CODES = new Set([
  'invalid_json', 'invalid_field', 'invalid_registration', 'invalid_email', 'club_contact_is_sender',
  'rights_required', 'privacy_required', 'too_many_files', 'bad_type', 'file_too_large', 'total_too_large',
  'unknown_registration', 'known_registration', 'size_mismatch', 'turnstile_failed', 'not_found',
  'missing_files', 'wrong_state', 'length_required', 'payload_too_large', 'bad_file', 'rate_limited',
  'internal', 'unavailable', 'daily_cap', 'lookup_unavailable', 'network',
]);

/**
 * The copy key for an error: its code when the worker names one we know, otherwise what its HTTP
 * status means, so a code added to the worker later still gets a sentence that says what to do.
 */
export function errorKey(err: unknown): string {
  if (!(err instanceof IntakeError)) return 'unknown';
  if (KNOWN_CODES.has(err.code)) return err.code;
  switch (err.status) {
    case 400: case 422: return 'invalid_field';
    case 401: case 403: return 'forbidden';
    case 404: case 410: return 'not_found';
    case 409: return 'wrong_state';
    case 411: return 'length_required';
    case 413: return 'payload_too_large';
    case 415: return 'bad_file';
    case 429: return 'rate_limited';
    case 503: return 'unavailable';
    default: return err.status >= 500 ? 'internal' : 'unknown';
  }
}

// ---------------------------------------------------------------------------------------------
// DOM
// ---------------------------------------------------------------------------------------------

type Child = Node | string | number | null | undefined | false;
type Attrs = Record<string, string | number | boolean | null | undefined | EventListener>;

/** createElement with attributes and text children (strings become text nodes, never markup). */
export function h<K extends keyof HTMLElementTagNameMap>(tag: K, attrs: Attrs = {}, ...children: Child[]): HTMLElementTagNameMap[K] {
  const el = document.createElement(tag);
  for (const [key, value] of Object.entries(attrs)) {
    if (value === null || value === undefined || value === false) continue;
    if (key.startsWith('on') && typeof value === 'function') el.addEventListener(key.slice(2), value);
    else if (key === 'class') el.className = String(value);
    else el.setAttribute(key, value === true ? '' : String(value));
  }
  for (const child of children) {
    if (child === null || child === undefined || child === false) continue;
    el.append(child instanceof Node ? child : String(child));
  }
  return el;
}

/** The token after `#t=`, read where it stays: the fragment never leaves the browser except to the worker. */
export function tokenFromHash(): string | null {
  const params = new URLSearchParams(location.hash.replace(/^#/, ''));
  const token = params.get('t')?.trim();
  return token && /^[A-Za-z0-9_-]{16,128}$/.test(token) ? token : null;
}

/** The "this page in the other language" link keeps the query and the fragment, so the
 *  registration (on /send) or the token (on /request and /confirm) comes along. */
export function wireLangSwitch(): void {
  document.querySelectorAll<HTMLAnchorElement>('[data-rq-lang]').forEach((a) => {
    const base = (a.getAttribute('href') ?? '').split(/[?#]/)[0];
    a.href = base + location.search + location.hash;
  });
}

/**
 * An error box: what happened, what to do, the code (for an e-mail to support), and a way on.
 * `key` picks another sentence when the page knows more than the code (a 404 while uploading is an
 * expired sending, not a link), `text` replaces it outright, `retry` adds the button.
 */
export function errorBox(copy: RequestsCopy, err: unknown, opts: { retry?: () => void; retryLabel?: string; key?: string; text?: string } = {}): HTMLElement {
  const code = err instanceof IntakeError ? err.code : 'unknown';
  const errors = copy.errors as Record<string, string>;
  const text = opts.text ?? errors[opts.key ?? errorKey(err)] ?? errors.unknown;
  return h('div', { class: 'rq-alert rq-alert--error', role: 'alert' },
    h('p', {}, text),
    h('p', { class: 'rq-alert-meta' },
      `${copy.common.code} ${code} · `,
      h('a', { href: copy.common.supportHref }, copy.common.support)),
    opts.retry ? h('button', { type: 'button', class: 'btn btn--ghost rq-retry', onclick: () => opts.retry!() }, opts.retryLabel ?? copy.common.retry) : null);
}

export function formatDate(value: unknown, withTime = false): string {
  if (value === null || value === undefined || value === '') return '';
  let date: Date;
  if (typeof value === 'number') date = new Date(value < 1e12 ? value * 1000 : value);
  else date = new Date(String(value));
  if (Number.isNaN(date.getTime())) return String(value);
  return new Intl.DateTimeFormat(lang === 'fr' ? 'fr-CH' : 'en-GB', withTime
    ? { day: 'numeric', month: 'long', year: 'numeric', hour: '2-digit', minute: '2-digit' }
    : { day: 'numeric', month: 'long', year: 'numeric' }).format(date);
}

export function formatSize(bytes: number, copy: RequestsCopy): string {
  const nf = (n: number, digits: number) => new Intl.NumberFormat(lang === 'fr' ? 'fr-CH' : 'en-US', { maximumFractionDigits: digits }).format(n);
  if (bytes < 1_000_000) return `${nf(Math.max(1, Math.round(bytes / 1000)), 0)} ${copy.units.kB}`;
  return `${nf(bytes / 1_000_000, 1)} ${copy.units.MB}`;
}

export function languageName(code: string): string {
  try {
    const name = new Intl.DisplayNames([lang], { type: 'language' }).of(code) ?? code;
    return name.charAt(0).toLocaleUpperCase(lang) + name.slice(1);
  } catch {
    return code.toUpperCase();
  }
}

/** A loading line that screen readers announce once. */
export function loadingLine(text: string): HTMLElement {
  return h('p', { class: 'rq-loading', role: 'status' }, h('span', { class: 'rq-spinner', 'aria-hidden': 'true' }), text);
}

/** A simple e-mail syntax check (the worker checks again): something@something.tld, no spaces. */
export function looksLikeEmail(value: string): boolean {
  return /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(value);
}

/** Marks a field as wrong (or right again), with its message under it. */
export function setFieldError(input: HTMLElement | null, message: string | null): void {
  if (!input) return;
  const errorId = input.getAttribute('data-rq-error') ?? `${input.id}-error`;
  const box = document.getElementById(errorId);
  if (message) {
    input.setAttribute('aria-invalid', 'true');
    if (box) { box.textContent = message; box.hidden = false; }
  } else {
    input.removeAttribute('aria-invalid');
    if (box) { box.textContent = ''; box.hidden = true; }
  }
}
