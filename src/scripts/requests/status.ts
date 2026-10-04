// /request#t=…: a request's page. GET /v1/status/:token, then the timeline, the club's state (with the
// form to add its contact when the worker allows it), the draft to proofread while the request is in
// `proofreading`, and the history. Never an e-mail address: the worker doesn't return any.
import { MESSAGE_MAX, STATUS_PATH } from '../../lib/intake';
import { renderChecklist, type ChecklistFile } from './checklist';
import {
  call, errorBox, errorKey, fill, formatDate, h, loadingLine, looksLikeEmail, readCopy, setFieldError,
  tokenFromHash, wireLangSwitch,
} from './shared';

/** An event's `status` is a request status, `club:<state>` or `proofread:<verdict>`. */
interface StatusEvent { status: string; at: string | number; message?: string; }
interface Status {
  ticket: string; kind: string; status: string; registrations?: string[]; aircraftType?: string;
  /** The club's name (null for an aircraft without one), its OK, and whether its contact can be added. */
  club?: { name?: string | null; state?: string; canAddContact?: boolean } | null;
  createdAt?: string | number; updatedAt?: string | number;
  events?: StatusEvent[]; draft?: boolean;
  /** The sender's own verdict on the draft, once given. */
  proofread?: 'ok' | 'issue' | null;
  locale?: string;
}

const root = document.querySelector<HTMLElement>('[data-rq-status]');
if (root) void init(root);

async function init(root: HTMLElement): Promise<void> {
  const copy = readCopy();
  const t = copy.status;
  const view = root.querySelector<HTMLElement>('[data-rq-view]')!;
  wireLangSwitch();

  const token = tokenFromHash();
  if (!token) {
    view.replaceChildren(h('h1', { class: 'rq-title' }, t.title), h('div', { class: 'rq-alert rq-alert--error', role: 'alert' }, h('p', {}, copy.errors.noToken)));
    return;
  }
  const base = `/v1/status/${encodeURIComponent(token)}`;
  let flash: { where: 'club'; text: string; tone: 'success' | 'info' } | null = null;

  async function load(): Promise<void> {
    try {
      const status = await call<Status>(base);
      render(status);
    } catch (err) {
      const dead = errorKey(err) === 'not_found';
      view.replaceChildren(h('h1', { class: 'rq-title' }, t.title), errorBox(copy, err, dead ? {} : {
        retry: () => {
          view.replaceChildren(h('h1', { class: 'rq-title' }, t.title), loadingLine(t.loading));
          void load();
        },
      }));
    }
  }

  function clubOf(s: Status): { name: string; state: string; canAddContact: boolean } {
    const c = s.club && typeof s.club === 'object' ? s.club : {};
    return { name: c.name ?? '', state: c.state ?? '', canAddContact: Boolean(c.canAddContact) };
  }

  function statusLabel(code: string): string {
    return copy.statuses[code]?.label ?? code;
  }

  /** The history's line for an event: a status, the club's answer, or the sender's verdict. */
  function eventLabel(code: string): string {
    const [kind, value] = code.split(':');
    if (kind === 'club' && value) return t.eventClub[value] ?? code;
    if (kind === 'proofread' && value) return t.eventProofread[value] ?? code;
    return statusLabel(code);
  }

  function badgeClass(code: string): string {
    if (code === 'live') return 'rq-badge rq-badge--live';
    if (code === 'need-info') return 'rq-badge rq-badge--attention';
    if (code === 'declined' || code === 'duplicate' || code === 'uploading') return 'rq-badge rq-badge--closed';
    return 'rq-badge';
  }

  function render(s: Status): void {
    const brand = document.title.includes('—') ? document.title.slice(document.title.indexOf('—')) : '';
    document.title = `${s.ticket} ${brand}`.trim();
    const events = Array.isArray(s.events) ? s.events : [];
    const club = clubOf(s);
    const line = copy.statuses[s.status]?.line;

    const facts: [string, string][] = [
      [t.labelRegistrations, (s.registrations ?? []).join(', ')],
      [t.labelAircraft, s.aircraftType ?? ''],
      [t.labelClub, club.name],
      [t.labelSent, formatDate(s.createdAt)],
      [t.labelUpdated, formatDate(s.updatedAt, true)],
    ];

    const parts: (HTMLElement | null)[] = [
      h('div', { class: 'rq-head' },
        h('h1', { class: 'rq-title' }, s.ticket),
        h('span', { class: badgeClass(s.status) }, statusLabel(s.status)),
        copy.kinds[s.kind] ? h('span', { class: 'rq-badge rq-badge--kind' }, copy.kinds[s.kind]) : null),
      line ? h('p', { class: 'rq-statusline' }, line) : null,
      h('div', { class: 'rq-card' },
        h('dl', { class: 'rq-facts' }, ...facts.filter(([, v]) => v).flatMap(([k, v]) => [h('dt', {}, k), h('dd', {}, v)]))),
      renderSteps(s.status, events),
      // An aircraft without a club has nothing to show here.
      club.state && (club.name || club.state !== 'not-needed') ? renderClub(club) : null,
      s.status === 'proofreading' && s.draft ? renderProofreading(s.proofread ?? null) : null,
      events.length ? renderHistory(events) : null,
    ];
    view.replaceChildren(...parts.filter((p): p is HTMLElement => p !== null));
  }

  function renderSteps(status: string, events: StatusEvent[]): HTMLElement {
    const reached = new Map<string, StatusEvent>();
    for (const e of events) if (!reached.has(e.status)) reached.set(e.status, e);
    const onPath = (STATUS_PATH as readonly string[]).indexOf(status);
    const branch = onPath < 0 ? status : null;
    // Off the path (need-info, declined, duplicate): the last step the request did reach.
    const last = onPath >= 0 ? onPath : Math.max(0, ...STATUS_PATH.map((p, i) => (reached.has(p) ? i : 0)));
    const closed = branch === 'declined' || branch === 'duplicate' || branch === 'uploading';

    const items: HTMLElement[] = [];
    const step = (cls: string, label: string, state: string, when?: StatusEvent, extra?: string) =>
      h('li', { class: cls },
        h('span', { class: 'rq-dot', 'aria-hidden': 'true' }, cls === 'is-done' ? '✓' : cls === 'is-closed' ? '×' : ''),
        h('span', {},
          h('span', { class: 'rq-step-label' }, label, h('span', { class: 'sr-only' }, ` (${state})`)),
          when ? h('span', { class: 'rq-step-meta' }, formatDate(when.at)) : null,
          extra ? h('span', { class: 'rq-step-line' }, extra) : null));

    STATUS_PATH.forEach((code, i) => {
      const label = statusLabel(code);
      if (i < last) {
        items.push(reached.has(code) || i === 0 ? step('is-done', label, t.stepDone, reached.get(code)) : step('is-skipped', label, t.stepSkipped));
      } else if (i === last) {
        const finished = branch !== null || code === 'live';
        items.push(step(finished ? 'is-done' : 'is-current', label, finished ? t.stepDone : t.stepCurrent, reached.get(code)));
        if (branch) {
          items.push(step(closed ? 'is-closed' : 'is-attention', statusLabel(branch), t.stepCurrent, reached.get(branch)));
        }
      } else if (!closed) {
        items.push(step('is-next', label, t.stepNext));
      }
    });

    return h('div', { class: 'rq-card' },
      h('h2', { class: 'rq-subtitle' }, t.stepsHeading),
      h('ol', { class: 'rq-steps' }, ...items),
      closed || status === 'live' ? null : h('p', { class: 'rq-note' }, t.noTimeline));
  }

  function renderClub(club: { state: string; canAddContact: boolean }): HTMLElement {
    const card = h('div', { class: 'rq-card', 'data-rq-club': '' },
      h('h2', { class: 'rq-subtitle' }, copy.club.heading),
      h('p', {}, copy.club.states[club.state] ?? club.state));
    if (flash?.where === 'club') {
      card.append(h('div', { class: `rq-alert rq-alert--${flash.tone}`, role: 'status' }, h('p', {}, flash.text)));
      flash = null;
    }
    if (club.state === 'pending' && club.canAddContact) card.append(contactForm());
    return card;
  }

  function contactForm(): HTMLElement {
    const c = copy.club;
    const input = h('input', {
      id: 'rq-add-contact', class: 'rq-input', type: 'email', autocomplete: 'off', spellcheck: 'false', maxlength: 254,
      'aria-describedby': 'rq-add-contact-hint rq-add-contact-error',
    });
    const button = h('button', { type: 'submit', class: 'btn btn--primary rq-btn' }, c.addButton);
    const errorHolder = h('div', {});
    const form = h('form', { class: 'rq-field', novalidate: true, style: 'margin-top: 16px' },
      h('p', {}, c.addLead),
      h('label', { class: 'rq-label', for: 'rq-add-contact' }, c.addLabel),
      h('p', { class: 'rq-hint', id: 'rq-add-contact-hint' }, c.addHint),
      h('div', { class: 'rq-inline' }, input, button),
      h('p', { class: 'rq-field-error', id: 'rq-add-contact-error', hidden: true }),
      errorHolder);
    input.addEventListener('input', () => setFieldError(input, null));
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const value = input.value.trim();
      errorHolder.replaceChildren();
      if (!value) { setFieldError(input, c.addRequired); input.focus(); return; }
      if (!looksLikeEmail(value)) { setFieldError(input, c.addInvalid); input.focus(); return; }
      button.disabled = true;
      try {
        await call(`${base}/club-contact`, { method: 'POST', body: { clubContactEmail: value } });
        flash = { where: 'club', text: c.addDone, tone: 'success' };
        await load();
        document.querySelector<HTMLElement>('[data-rq-club]')?.scrollIntoView({ block: 'center' });
      } catch (err) {
        const key = errorKey(err);
        button.disabled = false;
        if (key === 'invalid_email' || key === 'club_contact_is_sender') {
          setFieldError(input, key === 'invalid_email' ? c.addInvalid : c.addIsSender);
          input.focus();
        } else if (key === 'wrong_state') {
          flash = { where: 'club', text: copy.errors.contactClosed, tone: 'info' };
          await load();
        } else {
          errorHolder.replaceChildren(h('div', { style: 'margin-top: 12px' }, errorBox(copy, err)));
        }
      }
    });
    return form;
  }

  function renderProofreading(given: 'ok' | 'issue' | null): HTMLElement {
    const body = h('div', {}, loadingLine(t.proofLoading));
    const card = h('div', { class: 'rq-card', 'data-rq-proof': '' },
      h('h2', { class: 'rq-subtitle' }, t.proofHeading),
      h('p', {}, t.proofIntro),
      given ? h('div', { class: 'rq-alert rq-alert--info', role: 'status', style: 'margin-bottom: 4px' },
        h('p', {}, fill(t.proofYours, { verdict: given === 'ok' ? t.verdictOk : t.verdictIssue }))) : null,
      body);
    const loadDraft = async () => {
      body.replaceChildren(loadingLine(t.proofLoading));
      try {
        const draft = await call<{ files?: { name: string; json: ChecklistFile }[] }>(`${base}/draft`);
        const files = Array.isArray(draft?.files) ? draft.files : [];
        body.replaceChildren(...files.map((f, i) => renderChecklist(copy, f, i)), verdictForm());
      } catch (err) {
        body.replaceChildren(errorKey(err) === 'wrong_state'
          ? errorBox(copy, err, { key: 'proofClosed', retry: () => { void load(); } })
          : h('div', {}, h('p', {}, t.proofFailed), errorBox(copy, err, { retry: () => { void loadDraft(); } })));
      }
    };
    void loadDraft();
    return card;
  }

  function verdictForm(): HTMLElement {
    const message = h('textarea', {
      id: 'rq-verdict-msg', class: 'rq-input rq-textarea', rows: 4, maxlength: MESSAGE_MAX,
      'aria-describedby': 'rq-verdict-hint rq-verdict-count rq-verdict-msg-error',
    });
    const counter = h('p', { class: 'rq-counter', id: 'rq-verdict-count' });
    const updateCounter = () => { counter.textContent = fill(copy.send.counter, { n: message.value.length, max: MESSAGE_MAX }); };
    updateCounter();
    message.addEventListener('input', () => { updateCounter(); setFieldError(message, null); });
    const ok = h('button', { type: 'submit', class: 'btn btn--primary', value: 'ok' }, t.verdictOk);
    const issue = h('button', { type: 'submit', class: 'btn btn--ghost', value: 'issue' }, t.verdictIssue);
    const errorHolder = h('div', {});
    const form = h('form', { class: 'rq-verdict', novalidate: true },
      h('h3', { class: 'rq-subtitle' }, t.verdictLegend),
      h('label', { class: 'rq-label', for: 'rq-verdict-msg' }, t.verdictMessage),
      h('p', { class: 'rq-hint', id: 'rq-verdict-hint' }, t.verdictHint),
      message,
      counter,
      h('p', { class: 'rq-field-error', id: 'rq-verdict-msg-error', hidden: true }),
      errorHolder,
      h('div', { class: 'rq-verdict-buttons' }, ok, issue));
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const verdict = ((e as SubmitEvent).submitter as HTMLButtonElement | null)?.value === 'issue' ? 'issue' : 'ok';
      const text = message.value.trim();
      errorHolder.replaceChildren();
      if (verdict === 'issue' && !text) { setFieldError(message, t.verdictRequired); message.focus(); return; }
      if (text.length > MESSAGE_MAX) { setFieldError(message, t.verdictTooLong); message.focus(); return; }
      ok.disabled = issue.disabled = true;
      try {
        await call(`${base}/proofread`, { method: 'POST', body: { verdict, ...(text ? { message: text } : {}) } });
        const done = h('div', { class: 'rq-alert rq-alert--success', role: 'status', tabindex: '-1' },
          h('p', {}, verdict === 'ok' ? t.verdictThanksOk : t.verdictThanksIssue));
        form.replaceWith(done);
        done.focus();
      } catch (err) {
        const key = errorKey(err);
        ok.disabled = issue.disabled = false;
        if (key === 'invalid_field' && (err as { field?: string }).field === 'message') {
          setFieldError(message, t.verdictTooLong);
          message.focus();
        } else if (key === 'wrong_state') {
          form.replaceWith(errorBox(copy, err, { key: 'proofClosed', retry: () => { void load(); } }));
        } else {
          errorHolder.replaceChildren(h('div', { style: 'margin: 12px 0' }, errorBox(copy, err)));
        }
      }
    });
    return form;
  }

  function renderHistory(events: StatusEvent[]): HTMLElement {
    const sorted = [...events].sort((a, b) => new Date(b.at).getTime() - new Date(a.at).getTime());
    return h('div', { class: 'rq-card' },
      h('h2', { class: 'rq-subtitle' }, t.historyHeading),
      h('ol', { class: 'rq-history', reversed: true },
        ...sorted.map((e) => h('li', {},
          h('span', { class: 'rq-history-when' }, formatDate(e.at, true)),
          h('span', { class: 'rq-history-what' }, eventLabel(e.status)),
          e.message ? h('p', { class: 'rq-quote' }, e.message) : null))));
  }

  // A pasted link with a different token: load that request instead.
  window.addEventListener('hashchange', () => {
    if (tokenFromHash() && tokenFromHash() !== token) location.reload();
  });

  await load();
}
