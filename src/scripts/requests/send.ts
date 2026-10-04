// /send: the aircraft-request form (the intake worker's routes). In order: the
// registration's lookup (new or update), the checks a browser can make (fields, file types by their
// first bytes, the 4 / 10 MB / 25 MB limits), Turnstile, then the contract's sequence: POST the
// request, PUT each file to its upload slot (with progress, resumable), POST complete, show the ticket.
import {
  FILE_TYPES, MAX_FILES, MAX_FILE_BYTES, MAX_REGISTRATIONS, MAX_TOTAL_BYTES, NOTES_MAX,
  REGISTRATION_PATTERN, TURNSTILE_SCRIPT, TURNSTILE_SITE_KEY, TURNSTILE_TEST_KEY, type FileType,
} from '../../lib/intake';
import {
  IntakeError, call, errorBox, errorFromBody, errorKey, fill, formatSize, h, intakeUrl, lang, languageName,
  loadingLine, looksLikeEmail, readCopy, setFieldError, wireLangSwitch,
} from './shared';

interface Lookup {
  registration: string; known: boolean; aircraftId?: string; modelName?: string;
  aeroclub?: string; version?: string; languages?: string[];
}
interface Created { requestId: string; uploads: { n: number; url: string }[]; }
interface Completed { ticket: string; statusUrl: string; }
interface Picked { file: File; type: FileType; }

interface TurnstileApi {
  render(el: HTMLElement, options: Record<string, unknown>): string;
  reset(id?: string): void;
  getResponse(id?: string): string | undefined;
}
declare global {
  interface Window { turnstile?: TurnstileApi; rqTurnstileReady?: () => void; }
}

const root = document.querySelector<HTMLElement>('[data-rq-send]');
if (root) init(root);

function init(root: HTMLElement): void {
  const copy = readCopy();
  const t = copy.send;
  const fe = t.fieldErrors;
  wireLangSwitch();

  const $ = <T extends HTMLElement>(sel: string) => root.querySelector<T>(sel)!;
  const form = $<HTMLFormElement>('[data-rq-form]');
  const summary = $<HTMLElement>('[data-rq-summary]');
  const summaryList = $<HTMLUListElement>('[data-rq-summary-list]');
  const regInput = $<HTMLInputElement>('#rq-reg');
  const lookupBtn = $<HTMLButtonElement>('[data-rq-lookup]');
  const lookupBox = $<HTMLElement>('[data-rq-lookup-result]');
  const rest = $<HTMLElement>('[data-rq-rest]');
  const newOnly = $<HTMLElement>('[data-rq-new-only]');
  const typeInput = $<HTMLInputElement>('#rq-type');
  const clubInput = $<HTMLInputElement>('#rq-club');
  const regsInput = $<HTMLInputElement>('#rq-regs');
  const senderStep = $<HTMLElement>('[data-rq-sender]');
  const forGroup = $<HTMLElement>('#rq-for');
  const contactField = $<HTMLElement>('[data-rq-contact]');
  const contactInput = $<HTMLInputElement>('#rq-contact');
  const contactUnknown = $<HTMLInputElement>('#rq-contact-unknown');
  const filesHint = $<HTMLElement>('[data-rq-files-hint]');
  const chooseBtn = $<HTMLButtonElement>('[data-rq-choose]');
  const fileInput = $<HTMLInputElement>('[data-rq-file-input]');
  const drop = $<HTMLElement>('[data-rq-drop]');
  const filesList = $<HTMLUListElement>('[data-rq-files]');
  const filesTotal = $<HTMLElement>('[data-rq-files-total]');
  const langsGroup = $<HTMLElement>('#rq-langs');
  const otherLang = $<HTMLSelectElement>('#rq-lang-other');
  const nameInput = $<HTMLInputElement>('#rq-name');
  const emailInput = $<HTMLInputElement>('#rq-email');
  const notesInput = $<HTMLTextAreaElement>('#rq-notes');
  const notesCount = $<HTMLElement>('[data-rq-counter]');
  const rightsInput = $<HTMLInputElement>('#rq-rights');
  const rightsText = $<HTMLElement>('[data-rq-rights-text]');
  const privacyInput = $<HTMLInputElement>('#rq-privacy');
  const tsBox = $<HTMLElement>('[data-rq-turnstile]');
  const tsStatus = $<HTMLElement>('[data-rq-turnstile-status]');
  const tsError = $<HTMLElement>('#rq-turnstile');
  const submitBtn = $<HTMLButtonElement>('[data-rq-submit]');
  const submitError = $<HTMLElement>('[data-rq-submit-error]');
  const progress = $<HTMLElement>('[data-rq-progress]');
  const progressLine = $<HTMLElement>('[data-rq-progress-line]');
  const progressBar = $<HTMLProgressElement>('[data-rq-progress-bar]');
  const progressFiles = $<HTMLUListElement>('[data-rq-progress-files]');
  const progressError = $<HTMLElement>('[data-rq-progress-error]');
  const result = $<HTMLElement>('[data-rq-result]');

  let lookup: Lookup | null = null;
  let lookupFor = '';
  let picked: Picked[] = [];
  let busy = false;

  // ---- The registration ----------------------------------------------------------------------

  const normalise = (value: string) => value.toUpperCase().replace(/[‐-―−]/g, '-').replace(/\s+/g, '');

  async function runLookup(): Promise<boolean> {
    const value = normalise(regInput.value);
    setFieldError(regInput, null);
    if (!value) { setFieldError(regInput, fe.regRequired); return false; }
    if (!REGISTRATION_PATTERN.test(value)) { setFieldError(regInput, copy.errors.invalid_registration); return false; }
    if (lookup && lookupFor === value) return true;
    lookupBtn.disabled = true;
    lookupBox.replaceChildren(loadingLine(t.regChecking));
    try {
      const found = await call<Lookup>(`/v1/lookup?registration=${encodeURIComponent(value)}`);
      lookup = found;
      if (found.registration) regInput.value = found.registration;
      lookupFor = normalise(regInput.value);
      renderLookup(found);
      openRest();
      return true;
    } catch (err) {
      lookup = null;
      if (errorKey(err) === 'invalid_registration') {
        lookupBox.replaceChildren();
        setFieldError(regInput, copy.errors.invalid_registration);
      } else {
        lookupBox.replaceChildren(errorBox(copy, err, { retry: () => { void runLookup(); } }));
      }
      return false;
    } finally {
      lookupBtn.disabled = false;
    }
  }

  function renderLookup(found: Lookup): void {
    if (found.known) {
      const rows: [string, string | undefined][] = [
        [t.knownModel, found.modelName],
        [t.knownClub, found.aeroclub],
        [t.knownVersion, found.version],
        [t.knownLanguages, (found.languages ?? []).map((l) => languageName(l)).join(', ')],
      ];
      lookupBox.replaceChildren(h('div', { class: 'rq-alert rq-alert--info' },
        h('p', { class: 'rq-alert-title' }, fill(t.knownTitle, { reg: found.registration })),
        h('p', {}, t.knownBody),
        h('dl', { class: 'rq-facts' }, ...rows.filter(([, v]) => v).flatMap(([k, v]) => [h('dt', {}, k), h('dd', {}, v!)]))));
    } else {
      lookupBox.replaceChildren(h('div', { class: 'rq-alert rq-alert--info' },
        h('p', { class: 'rq-alert-title' }, fill(t.unknownTitle, { reg: found.registration })),
        h('p', {}, t.unknownBody)));
    }
    applyMode();
  }

  function openRest(): void {
    if (!rest.hidden) return;
    rest.hidden = false;
    loadTurnstile();
  }

  lookupBtn.addEventListener('click', () => { void runLookup(); });
  regInput.addEventListener('keydown', (e) => {
    if (e.key === 'Enter') { e.preventDefault(); void runLookup(); }
  });
  regInput.addEventListener('change', () => {
    if (normalise(regInput.value) && REGISTRATION_PATTERN.test(normalise(regInput.value))) void runLookup();
  });
  regInput.addEventListener('input', () => {
    if (lookup && normalise(regInput.value) !== lookupFor) {
      lookup = null;
      lookupBox.replaceChildren();
    }
  });

  // ---- The form's shape follows the answers ------------------------------------------------

  const isUpdate = () => Boolean(lookup?.known);
  const clubName = () => (isUpdate() ? lookup?.aeroclub ?? '' : clubInput.value.trim());
  const sendingFor = () => root.querySelector<HTMLInputElement>('input[name="sendingFor"]:checked')?.value as 'club' | 'self' | undefined;

  function applyMode(): void {
    const update = isUpdate();
    newOnly.hidden = update;
    filesHint.textContent = update ? t.filesHintUpdate : t.filesHintNew;
    if (update && lookup?.languages?.length && !checkedLanguages().length) {
      root.querySelectorAll<HTMLInputElement>('input[name="checklistLanguages"]').forEach((box) => {
        box.checked = lookup!.languages!.includes(box.value);
      });
      const other = lookup.languages.find((l) => !root.querySelector(`input[name="checklistLanguages"][value="${CSS.escape(l)}"]`));
      if (other && [...otherLang.options].some((o) => o.value === other)) otherLang.value = other;
    }
    const club = clubName();
    senderStep.hidden = !club;
    const self = sendingFor() === 'self';
    contactField.hidden = !(club && self);
    contactInput.disabled = contactUnknown.checked;
    if (contactUnknown.checked) setFieldError(contactInput, null);
    rightsText.textContent = !club ? t.rightsPrivate : self ? t.rightsSelf : t.rightsClub;
  }

  clubInput.addEventListener('input', applyMode);
  contactUnknown.addEventListener('change', applyMode);
  root.querySelectorAll<HTMLInputElement>('input[name="sendingFor"]').forEach((r) => r.addEventListener('change', () => {
    setFieldError(forGroup, null);
    applyMode();
  }));

  const updateCounter = () => { notesCount.textContent = fill(t.counter, { n: notesInput.value.length, max: NOTES_MAX }); };
  notesInput.addEventListener('input', updateCounter);
  updateCounter();

  // ---- Files ---------------------------------------------------------------------------------

  /** The type is read from the content, the way the worker checks it, never from the name. */
  async function sniff(file: File): Promise<FileType | null> {
    const b = new Uint8Array(await file.slice(0, 16).arrayBuffer());
    const ascii = (from: number, to: number) => String.fromCharCode(...b.slice(from, to));
    if (ascii(0, 5) === '%PDF-') return 'application/pdf';
    if (b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff) return 'image/jpeg';
    if (b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47) return 'image/png';
    if (ascii(4, 8) === 'ftyp' && ['heic', 'heix', 'mif1', 'msf1'].includes(ascii(8, 12))) return 'image/heic';
    return null;
  }

  function claimedType(file: File): FileType | null {
    const ext = file.name.split('.').pop()?.toLowerCase() ?? '';
    for (const [type, info] of Object.entries(FILE_TYPES)) {
      if ((info.extensions as readonly string[]).includes(ext) || file.type === type) return type as FileType;
    }
    return file.type === 'image/heif' ? 'image/heic' : null;
  }

  async function addFiles(list: Iterable<File>): Promise<void> {
    const problems: string[] = [];
    for (const file of list) {
      const name = file.name;
      if (picked.some((p) => p.file.name === name && p.file.size === file.size)) { problems.push(fill(fe.fileDuplicate, { name })); continue; }
      if (picked.length >= MAX_FILES) { problems.push(fe.tooManyFiles); break; }
      if (file.size === 0) { problems.push(fill(fe.fileEmpty, { name })); continue; }
      if (file.size > MAX_FILE_BYTES) { problems.push(fill(fe.fileTooBig, { name, size: formatSize(file.size, copy) })); continue; }
      const type = await sniff(file).catch(() => null);
      if (!type) {
        const claimed = claimedType(file);
        problems.push(claimed ? fill(fe.fileContent, { name, type: FILE_TYPES[claimed].label }) : fill(fe.fileType, { name }));
        continue;
      }
      const total = picked.reduce((sum, p) => sum + p.file.size, 0) + file.size;
      if (total > MAX_TOTAL_BYTES) { problems.push(fill(fe.totalTooBig, { size: formatSize(total, copy) })); continue; }
      picked.push({ file, type });
    }
    renderFiles();
    setFieldError(chooseBtn, problems.length ? problems.join(' ') : null);
  }

  function renderFiles(): void {
    filesList.replaceChildren(...picked.map((p, i) => h('li', { class: 'rq-file' },
      h('span', { class: 'rq-file-name' }, p.file.name),
      h('span', { class: 'rq-file-meta' }, `${FILE_TYPES[p.type].label} · ${formatSize(p.file.size, copy)}`),
      h('button', {
        type: 'button', class: 'rq-file-remove', 'aria-label': fill(t.filesRemoveLabel, { name: p.file.name }),
        onclick: () => { picked.splice(i, 1); renderFiles(); setFieldError(chooseBtn, null); chooseBtn.focus(); },
      }, t.filesRemove))));
    const total = picked.reduce((sum, p) => sum + p.file.size, 0);
    filesTotal.textContent = picked.length ? fill(t.filesTotal, { n: picked.length, size: formatSize(total, copy) }) : '';
    chooseBtn.disabled = picked.length >= MAX_FILES;
  }

  chooseBtn.addEventListener('click', () => fileInput.click());
  fileInput.addEventListener('change', () => {
    void addFiles(Array.from(fileInput.files ?? [])).then(() => { fileInput.value = ''; });
  });
  ['dragenter', 'dragover'].forEach((type) => drop.addEventListener(type, (e) => {
    e.preventDefault();
    drop.classList.add('is-over');
  }));
  ['dragleave', 'drop'].forEach((type) => drop.addEventListener(type, () => drop.classList.remove('is-over')));
  drop.addEventListener('drop', (e) => {
    e.preventDefault();
    if (e.dataTransfer?.files?.length) void addFiles(Array.from(e.dataTransfer.files));
  });

  // ---- Turnstile -----------------------------------------------------------------------------

  let turnstileState: 'idle' | 'loading' | 'ready' | 'failed' | 'closed' = 'idle';
  let widgetId: string | undefined;

  function siteKey(): string | null {
    if (TURNSTILE_SITE_KEY) return TURNSTILE_SITE_KEY;
    const host = location.hostname;
    const local = host === 'localhost' || host === '127.0.0.1' || host === '[::1]' || host.endsWith('.localhost');
    return local ? TURNSTILE_TEST_KEY : null;
  }

  function turnstileFailed(): void {
    turnstileState = 'failed';
    tsStatus.textContent = t.turnstileFailed;
  }

  function loadTurnstile(): void {
    if (turnstileState !== 'idle') return;
    const key = siteKey();
    if (!key) {
      turnstileState = 'closed';
      tsStatus.textContent = t.notOpen;
      submitBtn.disabled = true;
      return;
    }
    turnstileState = 'loading';
    tsStatus.textContent = t.turnstileLoading;
    window.rqTurnstileReady = () => {
      try {
        widgetId = window.turnstile!.render(tsBox, {
          sitekey: key,
          theme: 'dark',
          language: lang,
          size: 'flexible',
          callback: () => { tsStatus.textContent = ''; setFieldError(tsError, null); },
          'expired-callback': () => window.turnstile?.reset(widgetId),
          'error-callback': () => { tsStatus.textContent = t.turnstileFailed; },
        });
        turnstileState = 'ready';
        tsStatus.textContent = '';
      } catch {
        turnstileFailed();
      }
    };
    const script = document.createElement('script');
    script.src = `${TURNSTILE_SCRIPT}?render=explicit&onload=rqTurnstileReady`;
    script.async = true;
    script.onerror = turnstileFailed;
    document.head.append(script);
    window.setTimeout(() => { if (turnstileState === 'loading') turnstileFailed(); }, 20000);
  }

  const turnstileToken = () => (widgetId !== undefined ? window.turnstile?.getResponse(widgetId) : undefined);
  const resetTurnstile = () => { if (widgetId !== undefined) window.turnstile?.reset(widgetId); };

  // ---- Checks before sending -----------------------------------------------------------------

  function checkedLanguages(): string[] {
    const list = Array.from(root.querySelectorAll<HTMLInputElement>('input[name="checklistLanguages"]:checked')).map((b) => b.value);
    if (otherLang.value && !list.includes(otherLang.value)) list.push(otherLang.value);
    return list;
  }

  /** "HB-KFI, HB-KFO", one per line, or "HB-KFI HB-KFO"; "HB KFI" is one registration typed with a space. */
  function otherRegistrations(): { valid: string[]; invalid: string[] } {
    const valid: string[] = [];
    const invalid: string[] = [];
    for (const part of regsInput.value.split(/[,;\n]+/).map((p) => p.trim()).filter(Boolean)) {
      const pieces = part.split(/\s+/).map(normalise);
      if (pieces.length > 1 && pieces.every((p) => p.includes('-') && REGISTRATION_PATTERN.test(p))) valid.push(...pieces);
      else if (REGISTRATION_PATTERN.test(normalise(part))) valid.push(normalise(part));
      else invalid.push(part);
    }
    return { valid: [...new Set(valid)].filter((r) => r !== lookup?.registration), invalid };
  }

  /** A field, the message under it, and (when different) the line in the summary. */
  type Problem = [HTMLElement, string, string?];

  function validate(): Problem[] {
    const problems: Problem[] = [];
    const update = isUpdate();
    if (!update) {
      if (typeInput.value.trim().length < 2) problems.push([typeInput, fe.typeRequired]);
      const { valid, invalid } = otherRegistrations();
      if (invalid.length) problems.push([regsInput, fill(fe.otherRegsInvalid, { list: invalid.join(', ') })]);
      else if (valid.length + 1 > MAX_REGISTRATIONS) problems.push([regsInput, fe.tooManyRegs]);
    }
    if (clubName()) {
      const who = sendingFor();
      if (!who) problems.push([forGroup, fe.sendingForRequired]);
      if (who === 'self' && !contactUnknown.checked) {
        const contact = contactInput.value.trim();
        if (!contact) problems.push([contactInput, fe.contactRequired]);
        else if (!looksLikeEmail(contact)) problems.push([contactInput, fe.contactInvalid]);
        else if (contact.toLowerCase() === emailInput.value.trim().toLowerCase()) problems.push([contactInput, copy.errors.club_contact_is_sender]);
      }
    }
    if (!picked.length) problems.push([chooseBtn, fe.filesRequired]);
    if (!checkedLanguages().length) problems.push([langsGroup, fe.languagesRequired]);
    const email = emailInput.value.trim();
    if (!email) problems.push([emailInput, fe.emailRequired]);
    else if (!looksLikeEmail(email)) problems.push([emailInput, fe.emailInvalid]);
    if (notesInput.value.length > NOTES_MAX) problems.push([notesInput, fe.notesTooLong]);
    if (!rightsInput.checked) problems.push([rightsInput, fe.rightsRequired]);
    if (!privacyInput.checked) problems.push([privacyInput, fe.privacyRequired]);
    if (turnstileState === 'closed') problems.push([tsError, t.notOpen]);
    else if (turnstileState === 'failed') problems.push([tsError, t.turnstileFailed]);
    else if (!turnstileToken()) problems.push([tsError, t.turnstileMissing]);
    return problems;
  }

  const allFields: HTMLElement[] = [regInput, typeInput, regsInput, clubInput, forGroup, contactInput, chooseBtn,
    langsGroup, nameInput, emailInput, notesInput, rightsInput, privacyInput, tsError];

  function showProblems(problems: Problem[]): void {
    allFields.forEach((el) => setFieldError(el, null));
    problems.forEach(([el, msg]) => setFieldError(el, msg));
    summaryList.replaceChildren(...problems.map(([el, msg, line]) => h('li', {},
      h('a', { href: `#${el.id}`, onclick: (e: Event) => { e.preventDefault(); focusField(el); } }, line ?? msg))));
    summary.hidden = problems.length === 0;
    if (problems.length) summary.focus();
  }

  /** What the sender reads as the field's name: its label, or its group's legend. */
  function labelOf(el: HTMLElement): string {
    if (el === chooseBtn) return t.filesLabel;
    if (el === tsError) return t.turnstileLabel;
    const label = el.matches('fieldset') ? el.querySelector('legend') : root.querySelector(`label[for="${el.id}"]`) ?? el.closest('label');
    return (label?.textContent ?? '').replace(/\s+/g, ' ').trim() || el.id;
  }

  function focusField(el: HTMLElement): void {
    const target = el.matches('fieldset') ? el.querySelector<HTMLElement>('input, select') ?? el : el;
    target.scrollIntoView({ block: 'center' });
    target.focus({ preventScroll: true });
  }

  // Fields clear their own error as they are fixed.
  [typeInput, regsInput, contactInput, emailInput, notesInput].forEach((el) => el.addEventListener('input', () => setFieldError(el, null)));
  [rightsInput, privacyInput].forEach((el) => el.addEventListener('change', () => setFieldError(el, null)));
  langsGroup.addEventListener('change', () => setFieldError(langsGroup, null));

  /** The contract's field names, mapped to what the sender can fix. */
  const byField: Record<string, HTMLElement> = {
    registration: regInput, registrations: regInput, kind: regInput, aircraftType: typeInput, club: clubInput,
    sendingFor: forGroup, clubContactEmail: contactInput, senderName: nameInput, senderEmail: emailInput,
    checklistLanguages: langsGroup, notes: notesInput, rights: rightsInput, privacy: privacyInput,
    files: chooseBtn, turnstileToken: tsError,
  };

  // ---- Sending -------------------------------------------------------------------------------

  let created: Created | null = null;
  let uploadToken = '';
  let nextUpload = 0;
  let sentEmail = '';
  let sentWithContact = false;

  form.addEventListener('submit', (e) => {
    e.preventDefault();
    if (!busy) void submit();
  });

  async function submit(): Promise<void> {
    busy = true;
    submitBtn.disabled = true;
    submitError.replaceChildren();
    try {
      if (!(await runLookup())) {
        showProblems([[regInput, regInput.getAttribute('aria-invalid') ? (document.getElementById('rq-reg-error')?.textContent || fe.regLookup) : fe.regLookup]]);
        return;
      }
      applyMode();
      const problems = validate();
      showProblems(problems);
      if (problems.length) return;

      const update = isUpdate();
      const club = clubName();
      const who = club ? sendingFor()! : 'self';
      const contact = who === 'self' && club && !contactUnknown.checked ? contactInput.value.trim() : '';
      const notes = notesInput.value.trim();
      const name = nameInput.value.trim();
      const body: Record<string, unknown> = {
        kind: update ? 'update' : 'new',
        registrations: update ? [lookup!.registration] : [lookup!.registration, ...otherRegistrations().valid],
        aircraftType: update ? lookup!.modelName ?? '' : typeInput.value.trim(),
        ...(club ? { club } : {}),
        sendingFor: who,
        ...(contact ? { clubContactEmail: contact } : {}),
        ...(name ? { senderName: name } : {}),
        senderEmail: emailInput.value.trim(),
        checklistLanguages: checkedLanguages(),
        ...(notes ? { notes } : {}),
        locale: lang,
        rights: true,
        privacy: true,
        files: picked.map((p) => ({ name: p.file.name, size: p.file.size, type: p.type })),
        turnstileToken: turnstileToken(),
      };
      sentEmail = String(body.senderEmail);
      sentWithContact = Boolean(contact);

      showProgress(t.progressSending);
      try {
        created = await call<Created>('/v1/requests', { method: 'POST', body });
      } catch (err) {
        hideProgress();
        await reportSubmitError(err);
        return;
      } finally {
        resetTurnstile(); // a token is good for one try, whatever its outcome
      }
      const first = created.uploads?.[0];
      uploadToken = first ? intakeUrl(first.url).searchParams.get('u') ?? '' : '';
      nextUpload = 0;
      await runUploads();
    } finally {
      busy = false;
      submitBtn.disabled = turnstileState === 'closed';
    }
  }

  /** The codes that are about one field, and say so better than "check this field". */
  const FIELD_CODES = new Set(['invalid_registration', 'invalid_email', 'club_contact_is_sender', 'rights_required',
    'privacy_required', 'too_many_files', 'bad_type', 'file_too_large', 'total_too_large', 'turnstile_failed']);

  async function reportSubmitError(err: unknown): Promise<void> {
    const errors = copy.errors as Record<string, string>;
    let key = errorKey(err);
    const e = err instanceof IntakeError ? err : null;
    const field = e?.field;
    if (key === 'forbidden' || field === 'turnstileToken') key = 'turnstile_failed';

    // The app's list changed between the lookup and the sending: look again, and let the form follow.
    if (key === 'known_registration' || key === 'unknown_registration') {
      const named = Array.isArray(e?.data.registrations) ? (e!.data.registrations as unknown[]).map(String) : [];
      if (key === 'known_registration' && lookup && named.length && !named.includes(lookup.registration)) {
        // The registration typed first is new; some of the others aren't.
        submitError.replaceChildren(errorBox(copy, err, { key: 'invalid_field' }));
        showProblems([[regsInput, fill(fe.knownOthers, { list: named.join(', ') }), fill(fe.knownOthers, { list: named.join(', ') })]]);
        return;
      }
      const wasUpdate = isUpdate();
      lookup = null;
      lookupFor = '';
      await runLookup();
      // The form follows the new answer; if the lookup still says what it said, the list is moving.
      const switched = isUpdate() !== wasUpdate;
      submitError.replaceChildren(errorBox(copy, err, switched ? {} : { key: 'listChanged' }));
      lookupBox.scrollIntoView({ block: 'center' });
      return;
    }

    const target = field ? byField[field] : undefined;
    if (target) {
      // The Turnstile refusal says what to do next by itself; the others point at their field.
      submitError.replaceChildren(errorBox(copy, err, { key: key === 'turnstile_failed' ? key : 'invalid_field' }));
      if (FIELD_CODES.has(key)) showProblems([[target, errors[key]]]);
      else showProblems([[target, fe.field, fill(fe.fieldNamed, { label: labelOf(target) })]]);
    } else {
      submitError.replaceChildren(errorBox(copy, err, { key }));
      submitError.scrollIntoView({ block: 'center' });
    }
  }

  function showProgress(line: string): void {
    form.hidden = true;
    progress.hidden = false;
    progressError.replaceChildren();
    progressLine.textContent = line;
    progressBar.value = 0;
    progressFiles.replaceChildren(...picked.map((p) => h('li', { class: 'rq-progress-file' },
      h('span', { class: 'rq-progress-name' }, p.file.name),
      h('progress', { max: p.file.size, value: 0, 'aria-label': p.file.name }))));
    progress.focus();
  }

  function hideProgress(): void {
    progress.hidden = true;
    form.hidden = false;
  }

  function put(url: URL, item: Picked, onProgress: (loaded: number) => void): Promise<void> {
    return new Promise((resolve, reject) => {
      const xhr = new XMLHttpRequest();
      xhr.open('PUT', url.toString());
      xhr.setRequestHeader('Content-Type', item.type);
      xhr.upload.onprogress = (e) => onProgress(e.loaded);
      xhr.onload = () => {
        if (xhr.status >= 200 && xhr.status < 300) { onProgress(item.file.size); resolve(); return; }
        let body: unknown = null;
        try { body = JSON.parse(xhr.responseText); } catch { /* the status says enough */ }
        reject(errorFromBody(xhr.status, body));
      };
      xhr.onerror = () => reject(new IntakeError('network', 0));
      xhr.ontimeout = () => reject(new IntakeError('network', 0));
      xhr.send(item.file);
    });
  }

  async function runUploads(): Promise<void> {
    if (!created) return;
    progressError.replaceChildren();
    const uploads = [...created.uploads].sort((a, b) => a.n - b.n);
    const totalBytes = picked.reduce((sum, p) => sum + p.file.size, 0);
    const bars = Array.from(progressFiles.querySelectorAll('progress'));
    const doneBytes = () => uploads.slice(0, nextUpload).reduce((sum, u) => sum + (picked[u.n - 1]?.file.size ?? 0), 0);
    for (; nextUpload < uploads.length; nextUpload++) {
      const slot = uploads[nextUpload];
      const item = picked[slot.n - 1];
      if (!item) { failUpload(new IntakeError('internal', 0), null); return; }
      progressLine.textContent = fill(t.progressUpload, { i: nextUpload + 1, n: uploads.length, name: item.file.name });
      const before = doneBytes();
      try {
        await put(intakeUrl(slot.url), item, (loaded) => {
          if (bars[slot.n - 1]) bars[slot.n - 1].value = loaded;
          progressBar.value = Math.round(((before + loaded) / totalBytes) * 100);
        });
      } catch (err) {
        // Completed already (an answer lost on the way): the completion says with which ticket.
        if (errorKey(err) === 'wrong_state') break;
        if (bars[slot.n - 1]) bars[slot.n - 1].value = 0;
        progressBar.value = Math.round((before / totalBytes) * 100);
        failUpload(err, item);
        return;
      }
    }
    progressBar.value = 100;
    progressLine.textContent = t.progressFinishing;
    try {
      const done = await call<Completed>(`/v1/requests/${encodeURIComponent(created.requestId)}/complete?u=${encodeURIComponent(uploadToken)}`, { method: 'POST' });
      showResult(done);
    } catch (err) {
      const key = errorKey(err);
      if (key === 'wrong_state' && err instanceof IntakeError && typeof err.data.ticket === 'string') {
        showAlreadySent(err.data.ticket);
      } else if (key === 'missing_files') {
        // Something didn't arrive: send every file again, into the same slots.
        nextUpload = 0;
        progressError.replaceChildren(errorBox(copy, err, { retry: () => { void runUploads(); } }));
      } else {
        failUpload(err, null);
      }
    }
  }

  /** A second completion: the request went through before, and its link is in the sender's e-mail. */
  function showAlreadySent(ticket: string): void {
    progress.hidden = true;
    result.hidden = false;
    $<HTMLElement>('[data-rq-result-title]').textContent = fill(t.resultTitle, { ticket });
    $<HTMLElement>('[data-rq-result-body]').textContent = fill(copy.errors.alreadySent, { ticket });
    $<HTMLElement>('.rq-result-link').hidden = true;
    result.focus();
    result.scrollIntoView({ block: 'start' });
  }

  /**
   * A file the worker refused, or a sending it no longer has, sends the sender back to the form (the
   * next try is a new request); anything else can resume where it stopped.
   */
  function failUpload(err: unknown, item: Picked | null): void {
    const key = errorKey(err);
    const backToForm = ['bad_file', 'size_mismatch', 'length_required', 'not_found', 'invalid_field', 'bad_type',
      'file_too_large', 'total_too_large'].includes(key);
    if (backToForm) {
      created = null;
      const box = errorBox(copy, err, {
        key: key === 'not_found' ? 'uploadGone' : key,
        retry: () => { hideProgress(); chooseBtn.focus(); },
        retryLabel: copy.common.backToForm,
      });
      if (item && key !== 'not_found') box.prepend(h('p', { class: 'rq-alert-title' }, item.file.name));
      progressError.replaceChildren(box);
      return;
    }
    const box = errorBox(copy, err, { retry: () => { void runUploads(); } });
    if (item) box.prepend(h('p', {}, fill(t.uploadStopped, { name: item.file.name })));
    progressError.replaceChildren(box);
  }

  function showResult(done: Completed): void {
    progress.hidden = true;
    result.hidden = false;
    $<HTMLElement>('[data-rq-result-title]').textContent = fill(t.resultTitle, { ticket: done.ticket });
    $<HTMLElement>('[data-rq-result-body]').textContent = fill(t.resultBody, { email: sentEmail });
    const link = $<HTMLAnchorElement>('[data-rq-result-link]');
    let statusUrl = done.statusUrl;
    try {
      const url = new URL(done.statusUrl);
      if (url.protocol !== 'https:' && url.hostname !== location.hostname) statusUrl = '#';
    } catch { statusUrl = '#'; }
    link.href = statusUrl;
    const clubLine = $<HTMLElement>('[data-rq-result-club]');
    const club = clubName();
    if (club && sendingFor() === 'self') {
      clubLine.textContent = sentWithContact ? t.nextClub : t.nextClubNoContact;
      clubLine.hidden = false;
    }
    const copyBtn = $<HTMLButtonElement>('[data-rq-copy-link]');
    copyBtn.addEventListener('click', async () => {
      try {
        await navigator.clipboard.writeText(statusUrl);
        copyBtn.textContent = t.resultCopied;
        window.setTimeout(() => { copyBtn.textContent = t.resultCopy; }, 2500);
      } catch { /* the link is still there to long-press */ }
    });
    result.focus();
    result.scrollIntoView({ block: 'start' });
  }

  // ---- A registration in the address (/send?registration=HB-KFD, from /aircraft) -------------

  const fromQuery = new URLSearchParams(location.search).get('registration');
  if (fromQuery) {
    regInput.value = normalise(fromQuery).slice(0, 14);
    void runLookup();
  }
}
