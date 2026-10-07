// read_value: the current state of one form control (input, textarea, select, contenteditable).
// Run by Driver::Playwright#probe as `locator.evaluate(fn)`; must stay a single function expression.
(el) => {
  const tag = el.tagName.toLowerCase();
  const text = (node) =>
    node ? (node.innerText || node.textContent || '').trim().slice(0, 500) : '';
  let value = null;
  if (el.isContentEditable) value = el.innerText;
  else if ('value' in el) value = el.value;
  return {
    tag,
    value,
    checked: tag === 'input' && 'checked' in el ? el.checked : null,
    files: el.files ? Array.from(el.files, (file) => file.name) : [],
    text: tag === 'select' ? text(el.selectedOptions[0]) : text(el),
  };
};
