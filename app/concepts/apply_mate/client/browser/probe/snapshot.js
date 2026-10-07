// snapshot (minimal, phase 2): the interactive elements under root in document order.
// The full snapshot (stable selectors, aria, frames, widgets) arrives with phase 3a. Single function expression.
(root) => {
  const SELECTOR = [
    'input:not([type=hidden])',
    'textarea',
    'select',
    'button',
    '[contenteditable]:not([contenteditable=false])',
    '[role=button]',
    '[role=checkbox]',
    '[role=radio]',
    '[role=combobox]',
    '[role=textbox]',
  ].join(', ');
  const clean = (value) =>
    (value || '').replace(/\s+/g, ' ').trim().slice(0, 200) || null;
  const labelOf = (el) => {
    if (el.labels && el.labels.length) return clean(el.labels[0].innerText);
    if (el.getAttribute('aria-label'))
      return clean(el.getAttribute('aria-label'));
    const by = el.getAttribute('aria-labelledby');
    if (by)
      return clean(
        by
          .split(/\s+/)
          .map((id) => document.getElementById(id)?.innerText || '')
          .join(' '),
      );
    return null;
  };
  const visible = (el) => {
    const rect = el.getBoundingClientRect();
    const style = getComputedStyle(el);
    return (
      rect.width > 0 &&
      rect.height > 0 &&
      style.visibility !== 'hidden' &&
      style.display !== 'none'
    );
  };
  return Array.from(root.querySelectorAll(SELECTOR), (el, index) => ({
    index,
    tag: el.tagName.toLowerCase(),
    type: el.getAttribute('type'),
    name: el.getAttribute('name'),
    id: el.id || null,
    label: labelOf(el),
    placeholder: el.getAttribute('placeholder'),
    visible: visible(el),
  }));
};
