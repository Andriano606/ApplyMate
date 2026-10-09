// Options of open listboxes in one document (ARIA [role=option], Element UI .el-select-dropdown__item, and the
// ARIA-less lists of LOOSE_OPTIONS: an Alpine select's `[data-value]` items, the rows a typeahead renders into its
// `results` / `suggestions` container; only leaf items, never a "no results" / "loading" status), visible
// only, grouped by their container (the listbox id, else its css path). `containers` = { key => visible option
// count }; Session#dom_mark keeps it. With `since` (such a containers map) only options that are new since then are
// returned: their container was not open before, or their index in it is at or past the old count. This is the
// one "new since the click" diff; it never marks or mutates the DOM.
(root, { since }) => {
  const doc = root.ownerDocument || document;
  // Selector stability (see snapshot.js): a per-render UUID-prefixed id is never used as a container / option key.
  const UNSTABLE_ID =
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}_/i;
  const clean = (value) =>
    (value || '').replace(/\s+/g, ' ').trim().slice(0, 200);
  const visible = (el) => {
    const rect = el.getBoundingClientRect();
    if (rect.width <= 0 || rect.height <= 0) return false;
    const style = getComputedStyle(el);
    return style.visibility !== 'hidden' && style.display !== 'none';
  };
  const cssPath = (el) => {
    const segments = [];
    for (
      let node = el;
      node && node.nodeType === 1;
      node = node.parentElement
    ) {
      if (!node.parentElement) {
        segments.unshift(node.localName);
        break;
      }
      let index = 1;
      for (let s = node.previousElementSibling; s; s = s.previousElementSibling)
        if (s.localName === node.localName) index += 1;
      segments.unshift(`${node.localName}:nth-of-type(${index})`);
    }
    return segments.join(' > ');
  };
  const OPTIONS = '[role=option], .el-select-dropdown__item';
  const LOOSE_OPTIONS = [
    '[data-value]:not(input, select, option)',
    '[class*=results] > *',
    '[class*=suggestions] > *',
    ':is(ul, ol):is([class*=suggest], [class*=dropdown], [class*=autocomplete], [class*=options]) > li',
  ].join(', ');
  const STATUS =
    '[class*=no-result], [class*=noresult], [class*=loading], [class*=empty]';
  const candidates = () => {
    const strict = Array.from(doc.querySelectorAll(OPTIONS));
    const loose = Array.from(doc.querySelectorAll(LOOSE_OPTIONS)).filter(
      (item) =>
        !item.matches(OPTIONS) &&
        !item.closest(OPTIONS) &&
        !item.querySelector(`${OPTIONS}, ${LOOSE_OPTIONS}`) &&
        !item.closest(STATUS),
    );
    // Document order (a strict option keeps its place among loose ones).
    return Array.from(new Set([...strict, ...loose])).sort((a, b) =>
      a.compareDocumentPosition(b) & Node.DOCUMENT_POSITION_FOLLOWING ? -1 : 1,
    );
  };
  const containerOf = (option) =>
    option.closest('[role=listbox], .el-select-dropdown, ul') ||
    option.parentElement;
  const keyOf = (container) =>
    container.id ? `#${container.id}` : cssPath(container);

  const containers = {};
  const options = [];
  for (const option of candidates()) {
    if (!visible(option)) continue;
    const container = containerOf(option);
    const key = keyOf(container);
    const index = containers[key] || 0;
    containers[key] = index + 1;
    const isNew = !since || since[key] === undefined || index >= since[key];
    if (!isNew) continue;
    const label = clean(option.innerText || option.textContent);
    const strategies = [];
    if (option.id && !UNSTABLE_ID.test(option.id))
      strategies.push({ attr: { id: option.id } });
    if (option.getAttribute('role') === 'option' && label)
      strategies.push({ role: 'option', name: label });
    strategies.push({ css: cssPath(option) });
    options.push({
      label,
      value: option.getAttribute('data-value') || option.getAttribute('value'),
      selected:
        option.getAttribute('aria-selected') === 'true' ||
        option.classList.contains('selected'),
      disabled:
        option.getAttribute('aria-disabled') === 'true' ||
        option.classList.contains('is-disabled'),
      listbox_id: container.id || null,
      strategies,
    });
  }
  return { containers, options };
};
