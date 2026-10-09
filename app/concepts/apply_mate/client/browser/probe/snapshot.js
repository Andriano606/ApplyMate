// The one definition of "interactive element" (design §6.1). Runs on one document's root (Session#snapshot_all
// evaluates it in every frame), walks open shadow roots and returns elements with accessible name, state, field
// root, group and locator strategies, plus outline / alerts / captcha. Read-only: the DOM is never mutated. Field
// values are never returned (only `filled`). `regions` (CSS selectors, e.g. the platform's form root and excluded
// autofill panes) are reported per element: the ones the element or its field root sits inside.
(root, options) => {
  const doc = root.ownerDocument || document;
  const regions = (options && options.regions) || [];
  const MAX_ELEMENTS = 800;
  const MAX_OPTIONS = 200;
  const CANDIDATE_ROLES = new Set([
    'button',
    'link',
    'tab',
    'combobox',
    'listbox',
    'option',
    'radio',
    'radiogroup',
    'checkbox',
    'switch',
    'textbox',
    'menuitem',
    'dialog',
  ]);
  const LOCATABLE_ROLES = new Set([
    'button',
    'link',
    'tab',
    'combobox',
    'listbox',
    'option',
    'radio',
    'checkbox',
    'switch',
    'textbox',
    'menuitem',
    'searchbox',
    'spinbutton',
    'slider',
  ]);
  const NAMED_BY_CONTENT = new Set([
    'button',
    'link',
    'tab',
    'option',
    'menuitem',
    'switch',
    'checkbox',
    'radio',
  ]);
  const FIELD_CONTROLS = [
    'input:not([type=hidden]):not([type=submit]):not([type=button]):not([type=reset]):not([type=image])',
    'textarea',
    'select',
    '[contenteditable]:not([contenteditable=false])',
    '[role=textbox]',
    '[role=combobox]',
    '[role=radio]',
    '[role=checkbox]',
    '[role=switch]',
  ].join(', ');
  // Selector stability, not field keys: an id / name that starts with a per-render UUID (or React's `:r0:`) changes on
  // every load on ANY platform, so it is never offered as a locator strategy. Field-key prefix stripping is the
  // platform's job (Platform::Base#field_key, Readiness#key_prefix); these probes only refuse to locate by such ids.
  const INSTANCE_PREFIX =
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}_/i;
  const UNSTABLE_ID =
    /^:r[0-9a-z]*:|^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}_/i;
  const REQUIRED_CLASS = /(^|[_-])required([_-]|$)/i;
  const SUBMIT_TEXT = /submit|надіслати|відправити|подати заявку/i;
  const UPLOAD_LEXICON =
    /upload|attach|resume|\bcv\b|browse|завантаж|прикріп|резюме|загруз/i;
  const POPUP_ANCESTOR =
    '.el-select, .v-select, .select__control, [class*="select__control"]';
  const CHIP = '[class*=chip], [class*=singleValue], [class*=single-value]';

  const clean = (value, max = 200) =>
    (value || '').replace(/\s+/g, ' ').trim().slice(0, max);
  const stripMark = (text) => text.replace(/\s*[*✱]+\s*$/, '').trim();
  const typeOf = (el) =>
    (
      el.getAttribute('type') || (el.localName === 'input' ? 'text' : '')
    ).toLowerCase();
  const explicitRole = (el) =>
    (el.getAttribute('role') || '').trim().split(/\s+/)[0] || null;

  // Text of a node without the text of controls inside it (a label wrapping a <select> must not read its options).
  const ownText = (node) => {
    if (!node) return '';
    const parts = [];
    const visit = (current) => {
      for (const child of current.childNodes) {
        if (child.nodeType === 3) parts.push(child.nodeValue);
        else if (
          child.nodeType === 1 &&
          !child.matches(
            'select, textarea, input, script, style, [role=listbox], [aria-hidden=true]',
          )
        )
          visit(child);
      }
    };
    visit(node);
    return clean(parts.join(' '));
  };
  const textOf = (el) => (el ? clean(el.innerText || el.textContent) : '');

  const boxVisible = (el) => {
    const rect = el.getBoundingClientRect();
    if (rect.width <= 0 || rect.height <= 0) return false;
    const style = getComputedStyle(el);
    return style.visibility !== 'hidden' && style.display !== 'none';
  };
  // What a person sees: a box, not transparent (any ancestor), not clipped down to a pixel.
  const seen = (el) => {
    if (!el || el.nodeType !== 1 || !boxVisible(el)) return false;
    const rect = el.getBoundingClientRect();
    if (rect.width <= 1 && rect.height <= 1) return false;
    const style = getComputedStyle(el);
    if (style.clip === 'rect(0px, 0px, 0px, 0px)') return false;
    for (let node = el; node; node = node.parentElement) {
      if (parseFloat(getComputedStyle(node).opacity) === 0) return false;
    }
    return true;
  };
  const inViewport = (el) => {
    const rect = el.getBoundingClientRect();
    return (
      rect.bottom > 0 &&
      rect.right > 0 &&
      rect.top < innerHeight &&
      rect.left < innerWidth
    );
  };

  // `tag:nth-of-type(n)` chain from the document element; a shadow tree is its own chain after its host's
  // (Playwright's css engine pierces open shadow roots on the descendant combinator).
  const cssPath = (el) => {
    const trees = [];
    let segments = [];
    let node = el;
    while (node && node.nodeType === 1) {
      const tag = node.localName;
      const parent = node.parentNode;
      if (!parent || parent.nodeType === 9) {
        segments.unshift(tag);
        break;
      }
      let index = 1;
      for (let s = node.previousElementSibling; s; s = s.previousElementSibling)
        if (s.localName === tag) index += 1;
      segments.unshift(`${tag}:nth-of-type(${index})`);
      if (parent.nodeType === 11) {
        trees.unshift(segments.join(' > '));
        segments = [];
        node = parent.host;
      } else node = parent;
    }
    if (segments.length) trees.unshift(segments.join(' > '));
    return trees.join(' ');
  };

  const byIds = (el, attribute) => {
    const tree = el.getRootNode();
    return (el.getAttribute(attribute) || '')
      .split(/\s+/)
      .filter(Boolean)
      .map((id) => (tree.getElementById ? tree.getElementById(id) : null))
      .filter(Boolean);
  };

  const implicitRole = (el) => {
    const tag = el.localName;
    if (tag === 'button' || tag === 'summary') return 'button';
    if (tag === 'a') return el.hasAttribute('href') ? 'link' : null;
    if (tag === 'textarea') return 'textbox';
    if (tag === 'select')
      return el.multiple || el.size > 1 ? 'listbox' : 'combobox';
    if (tag !== 'input') return el.isContentEditable ? 'textbox' : null;
    const type = typeOf(el);
    if (['submit', 'button', 'reset', 'image'].includes(type)) return 'button';
    if (type === 'checkbox' || type === 'radio') return type;
    if (type === 'number') return 'spinbutton';
    if (type === 'search') return 'searchbox';
    if (type === 'range') return 'slider';
    if (type === 'file' || type === 'password') return null;
    return el.hasAttribute('list') ? 'combobox' : 'textbox';
  };
  const roleOf = (el) => explicitRole(el) || implicitRole(el);

  const isCandidate = (el) => {
    const tag = el.localName;
    if (tag === 'input') return typeOf(el) !== 'hidden';
    if (['textarea', 'select', 'button', 'summary'].includes(tag)) return true;
    if (tag === 'a' && el.hasAttribute('href')) return true;
    if (CANDIDATE_ROLES.has(explicitRole(el))) return true;
    return (
      el.isContentEditable &&
      !(el.parentElement && el.parentElement.isContentEditable)
    );
  };

  const groupKeyOf = (el) => {
    const type = typeOf(el);
    if (el.localName === 'input' && type === 'radio' && el.name)
      return `radio:${el.name}`;
    if (explicitRole(el) === 'radio') {
      const group = el.closest('[role=radiogroup]');
      if (group) return `radiogroup:${cssPath(group)}`;
    }
    return null;
  };
  // True when every field control under `node` belongs to el's own group (or is el).
  const soleGroup = (node, el) => {
    const key = groupKeyOf(el);
    for (const control of node.querySelectorAll(FIELD_CONTROLS)) {
      if (control === el) continue;
      if (!key || groupKeyOf(control) !== key) return false;
    }
    return true;
  };
  const fieldRootOf = (el, isField) => {
    const declared = el.closest('[data-field-path]');
    if (declared) return declared;
    for (
      let node = el.parentElement, depth = 0;
      node && depth < 8 && node !== doc.body && node.localName !== 'form';
      node = node.parentElement, depth += 1
    ) {
      if (
        node.matches('fieldset, [role=radiogroup], [role=group]') &&
        soleGroup(node, el)
      )
        return node;
    }
    if (!isField) return null;
    let top = null;
    for (
      let node = el.parentElement, depth = 0;
      node && depth < 6 && node !== doc.body && node.localName !== 'form';
      node = node.parentElement, depth += 1
    ) {
      if (!soleGroup(node, el)) break;
      top = node;
    }
    return top;
  };

  const questionElementOf = (fieldRoot) => {
    if (!fieldRoot) return null;
    const labelled = byIds(fieldRoot, 'aria-labelledby')[0];
    if (labelled) return labelled;
    const legend = fieldRoot.querySelector('legend');
    if (legend && ownText(legend)) return legend;
    for (const node of fieldRoot.querySelectorAll(
      'label, [class*=question], [class*=title], h2, h3, h4, h5, h6',
    )) {
      if (node.querySelector('input, select, textarea, button')) continue;
      const control = node.localName === 'label' ? node.control : null;
      if (control && ['radio', 'checkbox'].includes(typeOf(control))) continue;
      if (ownText(node)) return node;
    }
    return null;
  };
  const labelElementOf = (el) => {
    if (el.labels && el.labels.length) return el.labels[0];
    const parentLabel = el.closest('label');
    if (parentLabel) return parentLabel;
    const fieldset = el.closest('fieldset');
    return fieldset ? fieldset.querySelector('legend') : null;
  };
  // Text just before the control (a label-like div), never crossing another control or leaving the field root.
  const nearbyText = (el, fieldRoot) => {
    const controls = `${FIELD_CONTROLS}, button`;
    for (
      let node = el, depth = 0;
      node && depth < 3 && node !== doc.body && node !== fieldRoot;
      node = node.parentElement, depth += 1
    ) {
      for (
        let sibling = node.previousElementSibling;
        sibling;
        sibling = sibling.previousElementSibling
      ) {
        if (sibling.matches(controls) || sibling.querySelector(controls)) break;
        const text = textOf(sibling);
        if (text && text.length <= 150) return text;
      }
    }
    return '';
  };

  const nameOf = (el, role, labelEl, fieldRoot) => {
    const tag = el.localName;
    const type = typeOf(el);
    const labelledBy = clean(
      byIds(el, 'aria-labelledby').map(textOf).join(' '),
    );
    if (labelledBy) return stripMark(labelledBy);
    const aria = clean(el.getAttribute('aria-label'));
    if (aria) return stripMark(aria);
    const control = ['input', 'select', 'textarea'].includes(tag);
    if (
      !control &&
      (NAMED_BY_CONTENT.has(role) || tag === 'button' || tag === 'a')
    ) {
      const text = textOf(el) || clean(el.getAttribute('title'));
      if (text) return text;
    }
    if (tag === 'input' && ['submit', 'button', 'reset'].includes(type))
      return clean(el.value);
    if (tag === 'input' && type === 'image') return clean(el.alt);
    const label = stripMark(ownText(labelEl));
    if (label) return label;
    return (
      nearbyText(el, fieldRoot) ||
      clean(el.getAttribute('placeholder')) ||
      clean(el.getAttribute('title'))
    );
  };

  const marksRequired = (node) =>
    !!node &&
    (/[*✱]/.test(ownText(node)) ||
      Array.from(node.classList).some((token) => REQUIRED_CLASS.test(token)) ||
      !!node.querySelector('[class*=required]'));

  const dropzoneOf = (el) => {
    const parent = el.parentElement;
    const grand = parent && parent.parentElement;
    return [
      ...(el.labels ? Array.from(el.labels) : []),
      el.closest('[class*=dropzone]'),
      el.closest('[class*=upload]'),
      parent && parent.querySelector('button, [role=button]'),
      grand && grand.querySelector('button, [role=button]'),
    ].filter(Boolean);
  };

  const comboboxLike = (el, role) => {
    if (role === 'combobox' && el.localName !== 'select') return true;
    if (el.localName !== 'input' || !el.readOnly) return false;
    if (el.hasAttribute('aria-haspopup') || el.closest(POPUP_ANCESTOR))
      return true;
    const box = el.parentElement;
    return (
      !!box &&
      !!box.querySelector(
        'button, [class*=arrow], [class*=suffix], [class*=indicator], [class*=caret]',
      )
    );
  };

  const isButtonish = (el, role) =>
    el.localName === 'button' ||
    role === 'button' ||
    (el.localName === 'input' &&
      ['submit', 'button', 'image'].includes(typeOf(el)));
  const isSubmitType = (el) =>
    (el.localName === 'button' &&
      (typeOf(el) === 'submit' || (!el.hasAttribute('type') && !!el.form))) ||
    (el.localName === 'input' && ['submit', 'image'].includes(typeOf(el)));
  // A button (or drop area with role=button) that opens the file chooser itself: an upload word in its name and no
  // file input in its field root (else, without a root, its parent or grandparent) - the input is created on click.
  const choosesFile = (el, name, fieldRoot, buttonish, selfVisible) => {
    if (!buttonish || !selfVisible || isSubmitType(el)) return false;
    if (!UPLOAD_LEXICON.test(name)) return false;
    const parent = el.parentElement;
    const scope = fieldRoot || (parent && parent.parentElement) || parent;
    return !(scope && scope.querySelector('input[type=file]'));
  };
  const fieldsNearby = (el) => {
    let scope = el.form || null;
    if (!scope) {
      scope = el.parentElement;
      for (let depth = 0; scope && depth < 8; depth += 1) {
        if (scope.querySelector(FIELD_CONTROLS)) break;
        scope = scope.parentElement;
      }
    }
    if (!scope) return false;
    return Array.from(scope.querySelectorAll(FIELD_CONTROLS)).some(
      (control) => typeOf(control) === 'file' || seen(control),
    );
  };

  const strategiesOf = (el, role, name) => {
    const strategies = [];
    const id = el.id;
    if (id && !UNSTABLE_ID.test(id)) strategies.push({ attr: { id } });
    const htmlName = el.getAttribute('name');
    if (htmlName && !INSTANCE_PREFIX.test(htmlName)) {
      const type = typeOf(el);
      if ((type === 'radio' || type === 'checkbox') && el.hasAttribute('value'))
        strategies.push({
          attr: { name: htmlName, value: el.getAttribute('value') },
        });
      else strategies.push({ attr: { name: htmlName } });
    }
    if (role && LOCATABLE_ROLES.has(role) && name)
      strategies.push({ role, name });
    if (el.labels && el.labels.length) {
      const label = stripMark(ownText(el.labels[0]));
      if (label) strategies.push({ label });
    }
    strategies.push({ css: cssPath(el) });
    return strategies;
  };
  const rootStrategiesOf = (fieldRoot) => {
    if (!fieldRoot) return null;
    const strategies = [];
    const path = fieldRoot.getAttribute('data-field-path');
    if (path) strategies.push({ attr: { 'data-field-path': path } });
    if (fieldRoot.id && !UNSTABLE_ID.test(fieldRoot.id))
      strategies.push({ attr: { id: fieldRoot.id } });
    strategies.push({ css: cssPath(fieldRoot) });
    return strategies;
  };

  // The regions `el` (or its field root) sits inside; an invalid selector never matches.
  const regionsOf = (el, fieldRoot) =>
    regions.filter((selector) => {
      try {
        return !!(
          el.closest(selector) ||
          (fieldRoot && fieldRoot.closest(selector))
        );
      } catch (error) {
        return false;
      }
    });

  const candidates = [];
  const collect = (node) => {
    for (const el of node.querySelectorAll('*')) {
      if (isCandidate(el)) candidates.push(el);
      if (el.shadowRoot) collect(el.shadowRoot);
    }
  };
  collect(root);
  const truncated = candidates.length > MAX_ELEMENTS;
  const picked = candidates.slice(0, MAX_ELEMENTS);

  const described = picked.map((el, index) => {
    const tag = el.localName;
    const type = tag === 'input' ? typeOf(el) : null;
    const role = roleOf(el);
    const isField = el.matches(FIELD_CONTROLS);
    const fieldRoot = fieldRootOf(el, isField);
    const labelEl = labelElementOf(el);
    const questionEl = questionElementOf(fieldRoot);
    const name = nameOf(el, role, labelEl, fieldRoot);
    const question = questionEl ? stripMark(ownText(questionEl)) : '';
    const selfVisible = seen(el);
    let visible = selfVisible;
    if (!visible && type === 'file') visible = dropzoneOf(el).some(seen);
    else if (
      !visible &&
      (type === 'radio' || type === 'checkbox' || role === 'combobox')
    )
      visible =
        (!!labelEl && seen(labelEl)) || (!!fieldRoot && seen(fieldRoot));
    const ariaRequired = (node) =>
      !!node && node.getAttribute('aria-required') === 'true';
    const userInvalid = (() => {
      try {
        return el.matches(':user-invalid');
      } catch (error) {
        return false;
      }
    })();
    const autocomplete = (el.getAttribute('autocomplete') || '').toLowerCase();
    const buttonish = isButtonish(el, role);
    let group = null;
    if (groupKeyOf(el)) group = 'radio_group';
    else if (comboboxLike(el, role)) group = 'combobox';
    else if (
      buttonish &&
      fieldRoot &&
      !isSubmitType(el) &&
      question &&
      Array.from(
        fieldRoot.querySelectorAll('button, [role=button], [aria-pressed]'),
      ).filter((button) => !isSubmitType(button)).length >= 2
    )
      group = 'option_group';
    // Site chrome; a nav that is a tablist (Ashby's Overview | Application) is page content.
    const searchLike =
      type === 'search' ||
      role === 'searchbox' ||
      !!el.closest('[role=search], header, footer, nav:not([role=tablist])');
    const filled = !isField
      ? null
      : type === 'checkbox' || type === 'radio'
        ? !!el.checked
        : !!(el.isContentEditable
            ? (el.innerText || '').trim()
            : el.files
              ? el.files.length
              : el.value);
    return {
      el,
      fieldRoot,
      item: {
        index,
        tag,
        type,
        role,
        name,
        question: question || null,
        required:
          !!el.required ||
          ariaRequired(el) ||
          ariaRequired(fieldRoot) ||
          marksRequired(labelEl) ||
          marksRequired(questionEl),
        invalid: el.getAttribute('aria-invalid') === 'true' || userInvalid,
        checked:
          'checked' in el && (type === 'checkbox' || type === 'radio')
            ? el.checked
            : el.hasAttribute('aria-checked')
              ? el.getAttribute('aria-checked') === 'true'
              : null,
        expanded: el.hasAttribute('aria-expanded')
          ? el.getAttribute('aria-expanded') === 'true'
          : null,
        pressed: el.hasAttribute('aria-pressed')
          ? el.getAttribute('aria-pressed') === 'true'
          : null,
        selected: el.hasAttribute('aria-selected')
          ? el.getAttribute('aria-selected') === 'true'
          : null,
        disabled:
          !!el.disabled ||
          el.getAttribute('aria-disabled') === 'true' ||
          !!el.closest('fieldset[disabled]'),
        readonly: !!el.readOnly || el.getAttribute('aria-readonly') === 'true',
        visible,
        self_visible: selfVisible,
        in_viewport: visible && inViewport(selfVisible ? el : fieldRoot || el),
        aria_hidden: !!el.closest('[aria-hidden=true]'),
        filled,
        group,
        group_key: null,
        password:
          type === 'password' || /(current|new)-password/.test(autocomplete),
        search_like: searchLike,
        submit_like:
          buttonish &&
          !fieldRoot &&
          !searchLike &&
          (isSubmitType(el) ||
            SUBMIT_TEXT.test(`${name} ${el.getAttribute('class') || ''}`)) &&
          fieldsNearby(el),
        chooser: choosesFile(el, name, fieldRoot, buttonish, selfVisible),
        href: tag === 'a' ? clean(el.getAttribute('href'), 500) || null : null,
        options:
          tag === 'select'
            ? Array.from(el.options)
                .slice(0, MAX_OPTIONS)
                .map((option) => ({
                  label: clean(option.text),
                  value: option.value,
                  selected: option.selected,
                  disabled: option.disabled,
                }))
            : null,
        chip:
          group === 'combobox' && fieldRoot
            ? textOf(fieldRoot.querySelector(CHIP)) || null
            : null,
        strategies: strategiesOf(el, role, name),
        root_strategies: rootStrategiesOf(fieldRoot),
        regions: regionsOf(el, fieldRoot),
        attrs: {
          id: el.id || null,
          name: el.getAttribute('name'),
          type: el.getAttribute('type'),
          autocomplete: el.getAttribute('autocomplete'),
          placeholder: el.getAttribute('placeholder'),
          accept: el.getAttribute('accept'),
          multiple: el.hasAttribute('multiple'),
          maxlength: el.getAttribute('maxlength'),
          'aria-autocomplete': el.getAttribute('aria-autocomplete'),
          'aria-haspopup': el.getAttribute('aria-haspopup'),
          value:
            type === 'radio' || type === 'checkbox'
              ? el.getAttribute('value')
              : null,
          'data-field-path': fieldRoot
            ? fieldRoot.getAttribute('data-field-path')
            : null,
        },
      },
    };
  });

  // Radio groups (same name / role=radiogroup) and option groups (≥2 answer buttons in one field root): every
  // member gets group_key; the first one also lists the group's options.
  const groups = new Map();
  for (const entry of described) {
    const { item, el, fieldRoot } = entry;
    if (!item.group || item.group === 'combobox') continue;
    const key =
      item.group === 'radio_group'
        ? groupKeyOf(el)
        : `options:${cssPath(fieldRoot)}`;
    item.group_key = key;
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(entry);
  }
  for (const members of groups.values()) {
    members[0].item.options = members.slice(0, MAX_OPTIONS).map(({ item }) => ({
      label: item.name,
      value: item.attrs.value,
      checked: item.checked === null ? item.pressed : item.checked,
      strategies: item.strategies,
    }));
  }

  const outline = [];
  for (const heading of doc.querySelectorAll('h1, h2, h3')) {
    if (outline.length >= 40) break;
    if (seen(heading)) outline.push(`${heading.localName} ${textOf(heading)}`);
  }
  for (const list of doc.querySelectorAll('[role=tablist]')) {
    const tabs = Array.from(list.querySelectorAll('[role=tab]')).map(
      (tab) =>
        textOf(tab) + (tab.getAttribute('aria-selected') === 'true' ? '*' : ''),
    );
    if (tabs.length) outline.push(`tabs ${tabs.join(' | ')}`);
  }
  // A wizard's progress ("progressbar 1/3"): Engine::ClassifyAdvance reads it as evidence of a further page.
  for (const bar of doc.querySelectorAll('[role=progressbar], progress')) {
    if (outline.length >= 40) break;
    const native = bar.localName === 'progress';
    const now = native
      ? bar.value
      : parseFloat(bar.getAttribute('aria-valuenow'));
    const max = native
      ? bar.max
      : parseFloat(bar.getAttribute('aria-valuemax'));
    if (seen(bar) && Number.isFinite(now) && Number.isFinite(max))
      outline.push(`progressbar ${now}/${max}`);
  }
  for (const dialog of doc.querySelectorAll('dialog[open], [role=dialog]')) {
    if (seen(dialog))
      outline.push(
        `dialog ${clean(dialog.getAttribute('aria-label')) || textOf(dialog).slice(0, 80)}`,
      );
  }

  const alerts = Array.from(
    doc.querySelectorAll('[role=alert], [aria-live=assertive]'),
  )
    .filter(seen)
    .map(textOf)
    .filter(Boolean)
    .slice(0, 10);

  const captcha = [];
  const addCaptcha = (kind) => captcha.includes(kind) || captcha.push(kind);
  for (const frame of doc.querySelectorAll('iframe')) {
    const src = frame.src || '';
    if (/recaptcha\/(api2|enterprise)\/anchor/.test(src))
      addCaptcha(
        /[?&]size=invisible/.test(src) || !seen(frame)
          ? 'recaptcha_invisible'
          : 'recaptcha',
      );
    else if (/recaptcha\/(api2|enterprise)\/bframe/.test(src) && seen(frame))
      addCaptcha('recaptcha_challenge');
    else if (/hcaptcha/.test(src))
      addCaptcha(
        seen(frame) && frame.getBoundingClientRect().height > 30
          ? 'hcaptcha'
          : 'hcaptcha_invisible',
      );
    else if (/challenges\.cloudflare\.com/.test(src))
      addCaptcha(
        seen(frame) && frame.getBoundingClientRect().height > 30
          ? 'turnstile'
          : 'turnstile_invisible',
      );
    else if (/captcha-delivery\.com/.test(src)) addCaptcha('datadome');
  }
  if (doc.querySelector('.grecaptcha-badge')) addCaptcha('recaptcha_invisible');

  return {
    frame: { url: location.href, title: clean(doc.title) },
    outline,
    alerts,
    captcha,
    password_fields: described.filter(
      ({ item }) => item.password && item.visible,
    ).length,
    truncated,
    elements: described.map(({ item }) => item),
  };
};
