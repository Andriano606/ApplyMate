// A selector for `el` (a form root, a dialog) that survives layout changes, and the modal / dialog `el` acts in.
// Engine::Navigate stores a claimed form root by `selector` (a recipe's WaitFor replays it); Engine::ClassifyAdvance
// looks for the final button in `container` when the form root has none (a dialog footer outside its <form>).
//
// selectorOf(node), first that matches exactly `node` in its document:
//   1. #id                                 a stable id (not a React :r…: / per-render uuid id), a valid CSS ident
//   2. tag[data-*="v"] / tag[name="v"]     a data attribute or a name (form[name]) unique in the document
//   3. tag[role=r][aria-label="v"]         a role with an accessible name; tag[role=r] when the role is unique
//   4. form                                the document's only <form>
//   5. <anchor> > tag:nth-of-type(n) …     the nearest ancestor with one of 1-4, then the positional steps below it
//   null                                   nothing stable at all (the caller keeps its absolute nth-of-type path)
// Never anchors inside a shadow tree (the caller's path pierces it). `container`: the nearest dialog / modal ancestor
// (dialog, role dialog / alertdialog, aria-modal, Bootstrap's .modal) by selectorOf, else its absolute positional
// path; null when `el` is in none. model = { selector, container } (both nullable).
(el) => {
  const doc = el.ownerDocument;
  const UNSTABLE_ID =
    /^:r[0-9a-z]*:|^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|\d{5,}/i;
  const IDENT = /^[A-Za-z_][\w-]*$/;
  const MAX_VALUE = 80;
  const MAX_DEPTH = 6;
  const CONTAINER =
    'dialog, [role=dialog], [role=alertdialog], [aria-modal=true], .modal';
  const quote = (value) => `"${CSS.escape(value)}"`;
  const only = (selector, node) => {
    try {
      const found = doc.querySelectorAll(selector);
      return found.length === 1 && found[0] === node;
    } catch (error) {
      return false;
    }
  };
  const ownSelector = (node) => {
    const tag = node.localName;
    if (node.id && IDENT.test(node.id) && !UNSTABLE_ID.test(node.id)) {
      const selector = `#${node.id}`;
      if (only(selector, node)) return selector;
    }
    const attributes = Array.from(node.attributes).filter(
      (attr) =>
        (attr.name === 'name' || attr.name.startsWith('data-')) &&
        attr.value &&
        attr.value.length <= MAX_VALUE &&
        !UNSTABLE_ID.test(attr.value),
    );
    for (const attr of attributes) {
      const selector = `${tag}[${CSS.escape(attr.name)}=${quote(attr.value)}]`;
      if (only(selector, node)) return selector;
    }
    const role = node.getAttribute('role');
    if (role && IDENT.test(role)) {
      const label = node.getAttribute('aria-label');
      if (label && label.length <= MAX_VALUE) {
        const selector = `${tag}[role=${role}][aria-label=${quote(label)}]`;
        if (only(selector, node)) return selector;
      }
      if (only(`${tag}[role=${role}]`, node)) return `${tag}[role=${role}]`;
    }
    if (tag === 'form' && only('form', node)) return 'form';
    return null;
  };
  const step = (node) => {
    let index = 1;
    for (let s = node.previousElementSibling; s; s = s.previousElementSibling)
      if (s.localName === node.localName) index += 1;
    return `${node.localName}:nth-of-type(${index})`;
  };
  const selectorOf = (node) => {
    if (!node || node.getRootNode() !== doc) return null;
    const steps = [];
    for (
      let current = node;
      current && current !== doc.body && current !== doc.documentElement;
      current = current.parentElement
    ) {
      const own = ownSelector(current);
      if (own) {
        const selector = [own, ...steps].join(' > ');
        return only(selector, node) ? selector : null;
      }
      if (steps.length >= MAX_DEPTH) return null;
      steps.unshift(step(current));
    }
    return null;
  };
  // The container is only used within the run, so a positional path is good enough when nothing is stable.
  const absolutePath = (node) => {
    const steps = [];
    for (
      let current = node;
      current && current !== doc.body;
      current = current.parentElement
    )
      steps.unshift(step(current));
    return ['html', 'body', ...steps].join(' > ');
  };
  const container = el.closest(CONTAINER);
  const inside =
    container && container !== el && container.getRootNode() === doc;
  return {
    selector: selectorOf(el),
    container: inside ? selectorOf(container) || absolutePath(container) : null,
  };
};
