// Is the form under `root` rendered? Default: at least `min` visible fillable controls. Keys mode (`keys` given, the
// platform's schema keys): count the distinct keys found in `attr` of elements under root, any visibility (clipped
// file inputs and opacity:0 radios count); ready once found >= ceil(keys.length * ratio). `keyPrefix` (optional) is
// the platform's per-render prefix as a portable regex source (Platform::Base::Readiness#key_prefix, e.g. Ashby's
// INSTANCE_PREFIX_SOURCE), stripped from the start of each value case-insensitively; this probe knows no platform.
(root, { min, keys, attr, ratio, keyPrefix }) => {
  if (keys && keys.length) {
    const prefix = keyPrefix ? new RegExp(`^(?:${keyPrefix})`, 'i') : null;
    const wanted = new Set(keys);
    const found = new Set();
    for (const el of root.querySelectorAll(`[${CSS.escape(attr)}]`)) {
      const value = el.getAttribute(attr);
      const key = prefix ? value.replace(prefix, '') : value;
      if (wanted.has(key)) found.add(key);
    }
    return {
      fields: found.size,
      ready: found.size >= Math.ceil(wanted.size * ratio),
    };
  }
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
