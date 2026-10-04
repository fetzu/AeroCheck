// /confirm#t=…: the club's answer to a pilot's request. GET /v1/club/:token for what was sent, then
// POST the decision with the name and role of whoever answers for the club.
import { CLUB_MESSAGE_MAX } from '../../lib/intake';
import {
  call, errorBox, fill, formatDate, h, languageName, readCopy, setFieldError, tokenFromHash, wireLangSwitch,
} from './shared';

interface ClubRequest {
  ticket: string; registrations?: string[]; aircraftType?: string; club?: string; senderName?: string;
  checklistLanguages?: string[]; createdAt?: string | number; state?: string;
}

const root = document.querySelector<HTMLElement>('[data-rq-confirm]');
if (root) void init(root);

async function init(root: HTMLElement): Promise<void> {
  const copy = readCopy();
  const t = copy.confirm;
  const view = root.querySelector<HTMLElement>('[data-rq-view]')!;
  wireLangSwitch();

  const token = tokenFromHash();
  if (!token) {
    view.replaceChildren(h('div', { class: 'rq-alert rq-alert--error', role: 'alert' }, h('p', {}, copy.errors.noToken)));
    return;
  }
  const path = `/v1/club/${encodeURIComponent(token)}`;

  async function load(): Promise<void> {
    try {
      render(await call<ClubRequest>(path));
    } catch (err) {
      view.replaceChildren(errorBox(copy, err, () => { void load(); }));
    }
  }

  function render(r: ClubRequest): void {
    const sender = r.senderName?.trim() || t.senderUnknown;
    const facts: [string, string][] = [
      [t.labelTicket, r.ticket],
      [t.labelRegistrations, (r.registrations ?? []).join(', ')],
      [t.labelAircraft, r.aircraftType ?? ''],
      [t.labelClub, r.club ?? ''],
      [t.labelLanguages, (r.checklistLanguages ?? []).map((l) => languageName(l)).join(', ')],
      [t.labelSent, formatDate(r.createdAt)],
    ];
    const state = r.state ?? 'pending';
    const answer = state === 'pending'
      ? decisionForm()
      : h('div', { class: 'rq-alert rq-alert--info', role: 'status' }, h('p', {},
          state === 'confirmed' ? t.alreadyConfirmed : state === 'refused' ? t.alreadyRefused : t.notNeeded));

    view.replaceChildren(
      h('p', { class: 'rq-intro' }, r.club ? fill(t.intro, { sender, club: r.club }) : fill(t.introNoClub, { sender })),
      h('div', { class: 'rq-card' },
        h('dl', { class: 'rq-facts' }, ...facts.filter(([, v]) => v).flatMap(([k, v]) => [h('dt', {}, k), h('dd', {}, v)]))),
      h('div', { class: 'rq-card' },
        h('h2', { class: 'rq-subtitle' }, t.whatTitle),
        h('ul', { class: 'rq-list' }, ...t.what.map((line) => h('li', {}, line))),
        h('p', {}, t.refuseBody)),
      h('div', { class: 'rq-card' }, answer));
  }

  function decisionForm(): HTMLElement {
    const radio = (value: string, label: string) => h('label', { class: 'rq-choice' },
      h('input', { type: 'radio', name: 'decision', value }),
      h('span', {}, h('span', { class: 'rq-choice-title' }, label)));
    const decision = h('fieldset', { class: 'rq-choices', id: 'rq-decision', 'aria-describedby': 'rq-decision-error' },
      h('legend', { class: 'rq-label' }, t.decisionLegend),
      radio('confirm', t.confirm),
      radio('refuse', t.refuse),
      h('p', { class: 'rq-field-error', id: 'rq-decision-error', hidden: true }));
    const field = (id: string, label: string, input: HTMLElement, hint?: string) => h('div', { class: 'rq-field' },
      h('label', { class: 'rq-label', for: id }, label),
      hint ? h('p', { class: 'rq-hint', id: `${id}-hint` }, hint) : null,
      input,
      h('p', { class: 'rq-field-error', id: `${id}-error`, hidden: true }));
    const name = h('input', { id: 'rq-club-name', class: 'rq-input', type: 'text', autocomplete: 'name', maxlength: 120, 'aria-describedby': 'rq-club-name-error' });
    const role = h('input', { id: 'rq-club-role', class: 'rq-input', type: 'text', autocomplete: 'organization-title', maxlength: 120, 'aria-describedby': 'rq-club-role-hint rq-club-role-error' });
    const message = h('textarea', { id: 'rq-club-message', class: 'rq-input rq-textarea', rows: 3, maxlength: CLUB_MESSAGE_MAX, 'aria-describedby': 'rq-club-message-count rq-club-message-error' });
    const counter = h('p', { class: 'rq-counter', id: 'rq-club-message-count' });
    const updateCounter = () => { counter.textContent = fill(copy.send.counter, { n: message.value.length, max: CLUB_MESSAGE_MAX }); };
    updateCounter();
    const submit = h('button', { type: 'submit', class: 'btn btn--primary rq-submit' }, t.submit);
    const errorHolder = h('div', {});
    const messageField = field('rq-club-message', t.messageLabel, message);
    messageField.insertBefore(counter, messageField.lastChild);
    const form = h('form', { novalidate: true },
      decision,
      field('rq-club-name', t.nameLabel, name),
      field('rq-club-role', t.roleLabel, role, t.roleHint),
      messageField,
      h('p', { class: 'rq-hint' }, t.statement),
      errorHolder,
      submit);

    message.addEventListener('input', () => { updateCounter(); setFieldError(message, null); });
    [name, role].forEach((el) => el.addEventListener('input', () => setFieldError(el, null)));
    decision.addEventListener('change', () => setFieldError(decision, null));

    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      errorHolder.replaceChildren();
      const chosen = form.querySelector<HTMLInputElement>('input[name="decision"]:checked')?.value;
      const problems: [HTMLElement, string][] = [];
      if (!chosen) problems.push([decision, t.decisionRequired]);
      if (!name.value.trim()) problems.push([name, t.nameRequired]);
      if (!role.value.trim()) problems.push([role, t.roleRequired]);
      if (message.value.length > CLUB_MESSAGE_MAX) problems.push([message, t.messageTooLong]);
      [decision, name, role, message].forEach((el) => setFieldError(el, null));
      problems.forEach(([el, msg]) => setFieldError(el, msg));
      if (problems.length) {
        const first = problems[0][0];
        (first.matches('fieldset') ? first.querySelector<HTMLElement>('input')! : first).focus();
        return;
      }
      submit.disabled = true;
      const text = message.value.trim();
      try {
        await call(path, { method: 'POST', body: { decision: chosen, name: name.value.trim(), role: role.value.trim(), ...(text ? { message: text } : {}) } });
        const done = h('div', { class: 'rq-alert rq-alert--success', role: 'status', tabindex: '-1' },
          h('p', {}, chosen === 'confirm' ? t.doneConfirmed : t.doneRefused));
        form.replaceWith(done);
        done.focus();
      } catch (err) {
        errorHolder.replaceChildren(h('div', { style: 'margin: 0 0 12px' }, errorBox(copy, err)));
        submit.disabled = false;
      }
    });
    return form;
  }

  await load();
}
