// Does activating this element open a new browsing context? True when the element sits in a link (a / area with
// href) or a form whose target (its own, else the document's <base target>) names another context (_blank or a
// window name; not _self / _parent / _top). Recipe::Interpret then waits for the tab, which the browser reports
// 0.5-1.5 s after the click. window.open from a script is not visible here. Single function expression.
(el) => {
  const host = el.closest('a[href], area[href], form');
  if (!host) return false;
  const base = el.ownerDocument.querySelector('base[target]');
  const target = (
    host.getAttribute('target') ??
    base?.getAttribute('target') ??
    ''
  )
    .trim()
    .toLowerCase();
  return target !== '' && !['_self', '_parent', '_top'].includes(target);
};
