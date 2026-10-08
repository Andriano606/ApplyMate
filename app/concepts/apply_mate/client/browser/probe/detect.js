// Rendered-level platform evidence of one document (design §4): script and iframe sources, the iframes with their
// id/name (Operation::SnapshotAll builds `iframe#id` frame hops from them) and how many elements match each marker
// selector the platform registry asks about. An invalid marker selector counts 0. Read-only.
(root, { markers }) => {
  const doc = root.ownerDocument || document;
  const count = (selector) => {
    try {
      return doc.querySelectorAll(selector).length;
    } catch (error) {
      return 0;
    }
  };
  const frames = Array.from(doc.querySelectorAll('iframe, frame')).slice(0, 50);
  return {
    url: location.href,
    name: window.name || '',
    title: (doc.title || '').trim().slice(0, 200),
    script_srcs: Array.from(doc.scripts, (script) => script.src)
      .filter(Boolean)
      .slice(0, 200),
    iframe_srcs: frames.map((frame) => frame.src).filter(Boolean),
    iframes: frames.map((frame) => ({
      id: frame.id || null,
      name: frame.getAttribute('name'),
      src: frame.src || null,
    })),
    dom_markers: Object.fromEntries(
      (markers || []).map((selector) => [selector, count(selector)]),
    ),
  };
};
