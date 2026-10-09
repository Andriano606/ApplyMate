// Read-back of one control after a write (widgets verify every write with it). `displayed` is what the person sees:
// the selected option text, the contenteditable text, a combobox chip (react-select singleValue / multiValue, chip
// classes) inside the field root, the file names, or the input value. `invalid` = aria-invalid or :invalid;
// `marked_invalid` = an error class on the control (INVALID_CLASS);
// `error_text` = alert / live-region / aria-describedby text inside the field root; `pressed` = aria-pressed or
// aria-checked as written; `expanded` = aria-expanded="true" (a combobox whose menu is still open).
(el) => {
  const tag = el.tagName.toLowerCase();
  const type = (el.getAttribute('type') || '').toLowerCase();
  const CHIP =
    '[class*=chip], [class*=singleValue], [class*=multiValue], [class*=single-value], [class*=multi-value__label]';
  const text = (node) =>
    node
      ? (node.innerText || node.textContent || '')
          .replace(/\s+/g, ' ')
          .trim()
          .slice(0, 500)
      : '';
  const fieldRoot =
    el.closest('[data-field-path]') ||
    el.closest('fieldset') ||
    el.closest('[role=group]');
  const scopes = [];
  for (
    let node = el.parentElement, depth = 0;
    node && depth < 4;
    node = node.parentElement, depth += 1
  ) {
    scopes.push(node);
    if (node === fieldRoot) break;
  }
  if (fieldRoot && !scopes.includes(fieldRoot)) scopes.push(fieldRoot);

  let value = null;
  if (el.isContentEditable) value = el.innerText;
  else if ('value' in el) value = el.value;
  const files = el.files ? Array.from(el.files, (file) => file.name) : [];
  const combobox =
    el.getAttribute('role') === 'combobox' || el.hasAttribute('aria-haspopup');
  let chips = [];
  if (combobox) {
    for (const scope of scopes) {
      chips = Array.from(scope.querySelectorAll(CHIP))
        .filter((chip) => !chip.contains(el) && !chip.querySelector(CHIP))
        .map(text)
        .filter(Boolean);
      if (chips.length) break;
    }
  }
  const buttonish =
    tag === 'button' || (el.getAttribute('role') || '').trim() === 'button';
  let displayed;
  if (tag === 'select') displayed = text(el.selectedOptions[0]);
  else if (el.isContentEditable) displayed = text(el);
  else if (chips.length) displayed = chips.join(', ');
  else if (type === 'file') displayed = files.join(', ');
  else if (buttonish && combobox) displayed = text(el);
  else if (buttonish) displayed = text(fieldRoot || el.parentElement || el);
  else displayed = value;

  // A framework's error class on the control (Bootstrap is-invalid, is-error, has-error ...): server-side validation (a
  // 422 re-render) often sets only that. Reported apart as `marked_invalid`: a server-rendered class can outlive a
  // corrected value, so a write's read-back (`invalid`) must not depend on it; the post-submit evidence uses both.
  const INVALID_CLASS =
    /(^|[\s_-])(is-invalid|invalid|is-error|has-error|error)(?=$|[\s_-])/i;
  const markedInvalid = INVALID_CLASS.test(el.getAttribute('class') || '');
  let invalid = el.getAttribute('aria-invalid') === 'true';
  try {
    invalid = invalid || el.matches(':invalid');
  } catch (error) {
    // not a form control: aria-invalid only
  }
  const errorNodes = [];
  if (fieldRoot)
    errorNodes.push(...fieldRoot.querySelectorAll('[role=alert], [aria-live]'));
  const tree = el.getRootNode();
  for (const id of (el.getAttribute('aria-describedby') || '')
    .split(/\s+/)
    .filter(Boolean)) {
    const node = tree.getElementById ? tree.getElementById(id) : null;
    if (node) errorNodes.push(node);
  }
  const errorText = Array.from(new Set(errorNodes))
    .map(text)
    .filter(Boolean)
    .join(' ')
    .slice(0, 300);
  const pressed =
    el.getAttribute('aria-pressed') || el.getAttribute('aria-checked');

  const attr = (name) => el.getAttribute(name);

  return {
    tag,
    type: type || null,
    value,
    checked: tag === 'input' && 'checked' in el ? el.checked : null,
    files,
    text: tag === 'select' ? text(el.selectedOptions[0]) : text(el),
    displayed,
    invalid,
    marked_invalid: markedInvalid,
    error_text: errorText || null,
    pressed,
    expanded: attr('aria-expanded') === 'true',
    min: attr('min') ?? attr('aria-valuemin'),
    max: attr('max') ?? attr('aria-valuemax'),
    step: attr('step'),
    aria_valuenow: attr('aria-valuenow'),
  };
};
