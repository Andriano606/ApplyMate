// readiness: how many visible fillable controls the root contains, and whether that reaches `min`.
// Operation::WaitReady polls it until the form has rendered. Single function expression.
(root, { min }) => {
  const SELECTOR = [
    'input:not([type=hidden]):not([type=submit]):not([type=button]):not([type=reset]):not([type=image])',
    'textarea',
    'select',
    '[contenteditable]:not([contenteditable=false])',
    '[role=textbox]',
    '[role=combobox]',
  ].join(', ');
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
  const fields = Array.from(root.querySelectorAll(SELECTOR)).filter(
    visible,
  ).length;
  return { fields, ready: fields >= min };
};
