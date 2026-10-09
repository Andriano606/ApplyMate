// How many levels above `el` the pointer has to aim: 0 when `el` itself has a real box (both sides >= MIN_BOX px,
// opacity above 0), else the depth of the nearest such ancestor (at most MAX_DEPTH up, crossing a shadow host), null
// when none. A react-select DummyInput (1px wide, opacity 0, scale(.01), 100px left of its control) never passes
// Playwright's visible / stable checks; its control's value container does, and react-select opens on the control's
// mousedown. Engine::ClickControl clicks `{ ...strategy, ancestor: depth }` and keeps `el` for keys and read-back.
(el) => {
  const MIN_BOX = 4;
  const MAX_DEPTH = 4;
  const hasBox = (node) => {
    const rect = node.getBoundingClientRect();
    const style = node.ownerDocument.defaultView.getComputedStyle(node);
    return rect.width >= MIN_BOX && rect.height >= MIN_BOX && Number(style.opacity) > 0 &&
      style.visibility !== 'hidden' && style.display !== 'none';
  };
  let node = el;
  for (let depth = 0; node && depth <= MAX_DEPTH; depth += 1) {
    if (hasBox(node)) return depth;
    node = node.parentElement || node.getRootNode().host;
  }
  return null;
}
