// The one definition of "interactive element" (design §6.1). Runs on one document's root (Session#snapshot_all
// evaluates it in every frame), walks open shadow roots and returns elements with accessible name, state, field
// root, group and locator strategies, plus outline / alerts / captcha. Read-only: the DOM is never mutated. Field
// values are never returned (only `filled`). `regions` (CSS selectors, e.g. the platform's form root and excluded
// autofill panes) are reported per element: the ones the element or its field root sits inside.
(root, options) => {
  const doc = root.ownerDocument || document;
  const regions = (options && options.regions) || [];
  // The ONE send-the-application lexicon (Operation::SnapshotAll::SUBMIT_TEXT, also behind Engine::ClassifyAdvance's
  // FINAL_LEXICON): every caller passes it (SnapshotAll.probe_arg); a snapshot without it would silently stop marking
  // submit_like, the Navigator's no-submit guard, so it refuses to run.
  if (!options || !options.submitText)
    throw new Error('snapshot.js: options.submitText is required');
  const SUBMIT_TEXT = new RegExp(options.submitText, 'i');
  // The apply / respond verbs (SnapshotAll::APPLY_TEXT): submit_like only inside a dialog / form scope that holds a
  // fillable control (scopeHasFields), where they name the final button; elsewhere they are the page's launcher.
  if (!options.applyText) throw new Error('snapshot.js: options.applyText is required');
  const APPLY_TEXT = new RegExp(options.applyText, 'i');
  const MAX_ELEMENTS = 800;
  // fieldRootOf: how far up a control's field root reaches; past FIELD_ROOT_DEPTH only to find the field's question.
  const FIELD_ROOT_DEPTH = 6;
  const FIELD_ROOT_MAX_DEPTH = 12;
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
  const UPLOAD_LEXICON =
    /upload|attach|resume|\bcv\b|browse|завантаж|прикріп|резюме|загруз/i;
  const POPUP_ANCESTOR =
    '.el-select, .v-select, .select__control, [class*="select__control"]';
  const CHIP = '[class*=chip], [class*=singleValue], [class*=single-value]';
  // The list an ARIA-less typeahead fills after typing (Lever's `.dropdown-container > .dropdown-results`).
  const SUGGEST_CONTAINER =
    '[class*=dropdown], [class*=suggest], [class*=autocomplete], [class*=typeahead], [class*=results]';

  const clean = (value, max = 200) =>
    (value || '').replace(/\s+/g, ' ').trim().slice(0, max);
  // Required marks: a trailing one ("Email *") and a standalone one mid-label ("Resume/CV ✱ ...").
  const stripMark = (text) =>
    text
      .replace(/\s*[*✱]+\s*$/, '')
      .replace(/(^|\s)[*✱]+(?=\s)/g, '$1')
      .replace(/\s+/g, ' ')
      .trim();
  // A name / caption says something only with a letter: "+380", "$", "1." are affixes or numbering.
  const LETTER = /\p{L}/u;
  // A captcha's response field (g-recaptcha-response, h-captcha-response, cf-turnstile-response): never a question,
  // and the evidence of an invisible captcha the page has not framed yet.
  const CAPTCHA_RESPONSE = /^(g-recaptcha|h-captcha|cf-turnstile)-response/i;
  const typeOf = (el) =>
    (
      el.getAttribute('type') || (el.localName === 'input' ? 'text' : '')
    ).toLowerCase();
  const explicitRole = (el) =>
    (el.getAttribute('role') || '').trim().split(/\s+/)[0] || null;

  // Text of a node as a person reads it: without the text of controls inside it (a label wrapping a <select> must not
  // read its options), of a chooser link / button wrapping a control ("ATTACH RESUME/CV" around the file input) and of
  // CSS-hidden descendants (a typeahead's "No location found", an uploader's "Analyzing resume..." status). Inline
  // children join without a separator ("the&nbsp;<a>Privacy Policy</a>." stays "the Privacy Policy."), block ones
  // with a space.
  const ownText = (node) => {
    if (!node) return '';
    const parts = [];
    const visit = (current) => {
      const hiddenParent = getComputedStyle(current).visibility === 'hidden';
      for (const child of current.childNodes) {
        if (child.nodeType === 3) {
          parts.push(child.nodeValue);
          continue;
        }
        if (
          child.nodeType !== 1 ||
          child.matches(
            'select, textarea, input, script, style, [role=listbox], [aria-hidden=true]',
          ) ||
          (child.matches('a, button, [role=button]') &&
            child.querySelector(FIELD_CONTROLS))
        )
          continue;
        const style = getComputedStyle(child);
        if (
          style.display === 'none' ||
          (style.visibility === 'hidden' && !hiddenParent)
        )
          continue;
        const block =
          !style.display.startsWith('inline') && style.display !== 'contents';
        if (block) parts.push(' ');
        visit(child);
        if (block) parts.push(' ');
      }
    };
    visit(node);
    return clean(parts.join(''));
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
    // Pushed before the document origin by a negatively offset absolute / fixed box (the classic honeypot
    // `position:absolute; left:-9999px`): no scroll ever reveals it. A box merely scrolled out of an overflow
    // container is statically placed and keeps counting.
    const beforeOrigin =
      rect.right + scrollX <= 0 || rect.bottom + scrollY <= 0;
    for (let node = el; node; node = node.parentElement) {
      const nodeStyle = getComputedStyle(node);
      if (parseFloat(nodeStyle.opacity) === 0) return false;
      if (
        beforeOrigin &&
        (nodeStyle.position === 'absolute' || nodeStyle.position === 'fixed') &&
        (parseFloat(nodeStyle.left) < 0 || parseFloat(nodeStyle.top) < 0)
      )
        return false;
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
    // The widest ancestor up to FIELD_ROOT_DEPTH levels up that holds no other field. When that one carries no
    // question, a framework that wraps its input deeper (Vuetify: 7 levels below the item holding the title and its
    // "*") climbs on while the ancestor still holds no other field, up to FIELD_ROOT_MAX_DEPTH, and takes the first one
    // that carries a question; none -> the FIELD_ROOT_DEPTH one.
    const climbable = (node) =>
      node && node !== doc.body && node.localName !== 'form';
    let top = null;
    let node = el.parentElement;
    for (
      let depth = 0;
      depth < FIELD_ROOT_DEPTH && climbable(node);
      node = node.parentElement, depth += 1
    ) {
      if (!soleGroup(node, el)) return top;
      top = node;
    }
    if (!top || questionElementOf(top)) return top;
    for (
      let depth = FIELD_ROOT_DEPTH;
      depth < FIELD_ROOT_MAX_DEPTH && climbable(node) && soleGroup(node, el);
      node = node.parentElement, depth += 1
    ) {
      if (questionElementOf(node)) return node;
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
  const TEXT_ENTRY =
    'input:not([type]), input[type=text], input[type=email], input[type=tel], input[type=url], input[type=number], ' +
    'textarea, [contenteditable]:not([contenteditable=false]), [role=textbox]';
  // A <label for> whose control is not rendered (a framework's display:none twin: a Vue phone widget's hidden input,
  // a rich-text editor's hidden textarea) or does not exist (a dangling `for`), in a container whose ONLY rendered
  // text-entry control is `el`: the label belongs to what the person sees. The walk has no depth cap (a phone widget
  // nests its input 7 levels below the label's container); it ends at the FIRST ancestor that holds a second rendered
  // text control or any other <label for> - that ancestor decides: exactly one label there, orphaned, is adopted;
  // anything else (a label of a rendered control, two orphans, a checkbox / radio / file input's label) adopts
  // nothing. Never crosses a <form> or <body>.
  const orphanedLabel = (label) =>
    !label.control ||
    (!seen(label.control) &&
      !['checkbox', 'radio', 'file'].includes(typeOf(label.control)));
  const adoptedLabelOf = (el) => {
    if (!el.matches(TEXT_ENTRY) || !seen(el)) return null;
    for (
      let node = el.parentElement;
      node && node !== doc.body && node.localName !== 'form';
      node = node.parentElement
    ) {
      const others = Array.from(node.querySelectorAll(TEXT_ENTRY)).filter(
        (control) => control !== el && !el.contains(control) && seen(control),
      );
      if (others.length) return null;
      const labels = Array.from(node.querySelectorAll('label[for]')).filter(
        (label) => label.control !== el && !el.contains(label),
      );
      if (labels.length)
        return labels.length === 1 && orphanedLabel(labels[0])
          ? labels[0]
          : null;
    }
    return null;
  };
  // [label element, true when the browser itself names `el` by it (Playwright's getByRole name)].
  const labelElementOf = (el) => {
    if (el.labels && el.labels.length) return [el.labels[0], true];
    const parentLabel = el.closest('label');
    if (parentLabel) return [parentLabel, true];
    const fieldset = el.closest('fieldset');
    const legend = fieldset ? fieldset.querySelector('legend') : null;
    if (legend) return [legend, false];
    return [adoptedLabelOf(el), false];
  };
  // Text just before the control (a label-like div) - for a checkbox / radio first the text just AFTER it ("[ ] I agree
  // to ..."), never crossing another control or leaving the field root. Required marks stripped. Text before the
  // control that holds a link is navigation ("Powered by <a>PeopleForce</a>" beside a footer locale select), not a
  // caption; a link inside the text AFTER a checkbox is the consent wording itself ("I agree to the <a>Policy</a>").
  // A letterless text ("+380", "$") is the value's affix (prefixOf), never a caption: the scan passes over it.
  const nearbyText = (el, fieldRoot, following) => {
    const controls = `${FIELD_CONTROLS}, button`;
    const scan = (start, step, stop) => {
      for (let sibling = start; sibling; sibling = step(sibling)) {
        if (sibling.matches(stop) || sibling.querySelector(stop)) return '';
        const text = stripMark(textOf(sibling));
        if (text && text.length <= 150 && LETTER.test(text)) return text;
      }
      return '';
    };
    for (
      let node = el, depth = 0;
      node && depth < 3 && node !== doc.body && node !== fieldRoot;
      node = node.parentElement, depth += 1
    ) {
      const text =
        (following &&
          scan(
            node.nextElementSibling,
            (n) => n.nextElementSibling,
            controls,
          )) ||
        scan(
          node.previousElementSibling,
          (n) => n.previousElementSibling,
          following ? controls : `${controls}, a[href]`,
        );
      if (text) return text;
    }
    return '';
  };
  // The fixed letterless text just before a text input inside its field (Hurma's `<span>+380</span><input type=tel>`,
  // a "$" before a salary): an affix of the value, not its name. Only the nearest rendered text counts (a lettered one
  // ends the search), never crossing another control or leaving the field root.
  const AFFIX_TYPES = new Set(['text', 'tel', 'number', 'email', 'url']);
  const prefixOf = (el, fieldRoot) => {
    if (el.localName !== 'input' || !AFFIX_TYPES.has(typeOf(el))) return '';
    const controls = `${FIELD_CONTROLS}, button`;
    for (
      let node = el, depth = 0;
      node && depth < 2 && node !== doc.body && node !== fieldRoot;
      node = node.parentElement, depth += 1
    ) {
      for (
        let sibling = node.previousElementSibling;
        sibling;
        sibling = sibling.previousElementSibling
      ) {
        if (sibling.matches(controls) || sibling.querySelector(controls))
          return '';
        const text = seen(sibling) ? textOf(sibling) : '';
        if (text) return text.length <= 8 && !LETTER.test(text) ? text : '';
      }
    }
    return '';
  };
  // A field's help text: the first rendered text block after its question / label element inside the field root (up to
  // 3 levels up from it), before any control - not a label, not an error / live message, not the question again.
  const HELP_SKIP =
    'label, legend, [role=alert], [aria-live], [class*=error], [class*=invalid]';
  const helpTextOf = (fieldRoot, anchors, question) => {
    if (!fieldRoot) return '';
    const controls = `${FIELD_CONTROLS}, button, [role=button]`;
    for (const anchor of anchors) {
      if (!anchor || anchor === fieldRoot || !fieldRoot.contains(anchor))
        continue;
      for (
        let node = anchor, depth = 0;
        node && node !== fieldRoot && depth < 3;
        node = node.parentElement, depth += 1
      ) {
        for (
          let sibling = node.nextElementSibling;
          sibling;
          sibling = sibling.nextElementSibling
        ) {
          if (sibling.matches(controls) || sibling.querySelector(controls))
            return '';
          if (sibling.matches(HELP_SKIP) || !seen(sibling)) continue;
          const text = clean(sibling.innerText || sibling.textContent, 300);
          if (text && stripMark(text) !== question) return text;
        }
      }
    }
    return '';
  };
  // A nameless icon button's purpose from its class tokens (`<div class="close-btn" role="button">`).
  const CLOSE_CLASS = /(^|[-_\s])(close|dismiss)([-_\s]|$)/i;

  // { name, accessible }: `name` is what the snapshot reports; `accessible` the name the browser computes (the
  // {role, name} locator strategy), null when the name came from a heuristic (nearby text, an adopted label, the
  // field root's question) the browser never sees. A control's title that only repeats its own value is no name.
  const nameOf = (el, role, labelEl, labelOwn, fieldRoot, question) => {
    const tag = el.localName;
    const type = typeOf(el);
    const named = (name, accessible) => ({ name, accessible });
    const labelledBy = clean(
      byIds(el, 'aria-labelledby').map(textOf).join(' '),
    );
    if (labelledBy) return named(stripMark(labelledBy), labelledBy);
    const aria = clean(el.getAttribute('aria-label'));
    if (aria) return named(stripMark(aria), aria);
    const control = ['input', 'select', 'textarea'].includes(tag);
    const title = clean(el.getAttribute('title'));
    // A custom select's trigger shows its current value ("USD", "Select..."): named by its label, never its content.
    if (
      !control &&
      !popupTrigger(el) &&
      (NAMED_BY_CONTENT.has(role) || tag === 'button' || tag === 'a')
    ) {
      const text = textOf(el) || title;
      if (text) return named(text, text);
      // An empty button / link is named by nothing outside itself (a hidden captcha submit must not take the page
      // heading); a close icon by its class.
      if (
        role === 'button' ||
        role === 'link' ||
        tag === 'button' ||
        tag === 'a'
      )
        return named(
          CLOSE_CLASS.test(el.getAttribute('class') || '') ? 'close' : '',
          null,
        );
    }
    if (tag === 'input' && ['submit', 'button', 'reset'].includes(type))
      return named(clean(el.value), clean(el.value));
    if (tag === 'input' && type === 'image')
      return named(clean(el.alt), clean(el.alt));
    const label = stripMark(ownText(labelEl));
    if (label) return named(label, labelOwn ? label : null);
    const placeholder = clean(el.getAttribute('placeholder'));
    const ownTitle = title && title !== clean(el.value) ? title : '';
    const fallback = placeholder || ownTitle;
    const nearby = nearbyText(
      el,
      fieldRoot,
      type === 'checkbox' ||
        type === 'radio' ||
        role === 'checkbox' ||
        role === 'radio',
    );
    if (nearby) return named(nearby, fallback || null);
    if (fallback) return named(fallback, fallback);
    return named(type === 'file' ? question : '', null);
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

  // A custom select's trigger (Headless UI / Radix / MUI: a button or div that pops a listbox up).
  const popupTrigger = (el) =>
    el.getAttribute('aria-haspopup') === 'listbox' &&
    !['select', 'input', 'textarea'].includes(el.localName);
  const comboboxLike = (el, role) => {
    if (role === 'combobox' && el.localName !== 'select') return true;
    if (popupTrigger(el)) return true;
    if (el.localName !== 'input' || !el.readOnly) return false;
    if (el.hasAttribute('aria-haspopup') || el.closest(POPUP_ANCESTOR))
      return true;
    const box = el.parentElement;
    if (
      box &&
      box.querySelector(
        'button, [class*=arrow], [class*=suffix], [class*=indicator], [class*=caret]',
      )
    )
      return true;
    // A readonly input whose wrapper (up to 4 ancestors) holds a list of 2+ options (`[role=option]` / `[data-value]`
    // items, an Alpine / jQuery select): clicking it opens the list.
    for (
      let node = box, depth = 0;
      node && depth < 4 && node !== doc.body && node.localName !== 'form';
      node = node.parentElement, depth += 1
    ) {
      const items = Array.from(
        node.querySelectorAll('[role=option], [data-value]'),
      ).filter((item) => !item.contains(el));
      if (items.length >= 2) return true;
    }
    return false;
  };

  // An ARIA-less typeahead (Lever's location input): a free-text input beside a suggestion container its script fills
  // after typing, within 2 ancestors that hold no other field. BuildFieldInventory makes it an `autocomplete` written by
  // Widget::Typeahead (pick a suggestion, else keep the typed text).
  const typeaheadLike = (el, role) => {
    if (el.localName !== 'input' || typeOf(el) !== 'text') return false;
    if (el.readOnly || role === 'combobox' || el.hasAttribute('list'))
      return false;
    for (
      let node = el.parentElement, depth = 0;
      node && depth < 2 && node !== doc.body && node.localName !== 'form';
      node = node.parentElement, depth += 1
    ) {
      const others = Array.from(node.querySelectorAll(FIELD_CONTROLS));
      if (others.some((other) => other !== el)) return false;
      const boxes = Array.from(node.querySelectorAll(SUGGEST_CONTAINER));
      if (boxes.some((box) => !box.contains(el))) return true;
    }
    return false;
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
  // file input in its field root, nor in the uploader around it (up to 4 ancestors, stopping at a <form> or at an
  // ancestor that holds another kind of field: a dropzone `<div role=presentation>` with its hidden input) - the input
  // is created on click.
  const choosesFile = (el, name, fieldRoot, buttonish, selfVisible) => {
    if (!buttonish || !selfVisible || isSubmitType(el)) return false;
    if (!UPLOAD_LEXICON.test(name)) return false;
    if (fieldRoot) return !fieldRoot.querySelector('input[type=file]');
    for (
      let node = el.parentElement, depth = 0;
      node && depth < 4 && node !== doc.body && node.localName !== 'form';
      node = node.parentElement, depth += 1
    ) {
      if (node.querySelector('input[type=file]')) return false;
      if (node.querySelector(FIELD_CONTROLS)) return true;
    }
    return true;
  };
  // A link / button that only opens the chooser of a file input it wraps (Lever's "ATTACH RESUME/CV" anchor) or sits
  // beside under an upload word (Ashby's "Upload file", Greenhouse's "Attach"): part of that file field, never a field
  // or a link of its own (Prompt::Navigate leaves it out, ExecuteAction refuses to click it).
  const fileTriggerOf = (el, name, buttonish, chooser) => {
    if (chooser || !(buttonish || el.localName === 'a') || isSubmitType(el))
      return false;
    if (el.querySelector('input[type=file]')) return true;
    for (
      let node = el.parentElement, depth = 0;
      node && depth < 3 && node !== doc.body && node.localName !== 'form';
      node = node.parentElement, depth += 1
    ) {
      const files = node.querySelectorAll('input[type=file]');
      if (files.length) return files.length === 1 && UPLOAD_LEXICON.test(name);
    }
    return false;
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

  // The container an element acts in, for SnapshotAll's fingerprint and ExecuteAction's no-submit guard: 'dialog'
  // (an open modal, `<dialog>` / role=dialog / aria-modal), else 'form', plus `#id` when the container has a stable
  // id, else `@n` (its 1-based position among the same kind of containers in its document / shadow root, so two id-less
  // forms are two scopes: a newsletter form's email never makes another form's "Apply" a send); null on the page
  // itself. A modal's "Відгукнутися" is then never the page launcher of the same name, however the modal is inserted
  // into the DOM.
  const SCOPE_DIALOG =
    'dialog, [role=dialog], [role=alertdialog], [aria-modal=true]';
  const scopeLabels = new Map();
  const scopeOf = (el) => {
    const dialog = el.closest(SCOPE_DIALOG);
    const container = dialog || el.form || el.closest('form');
    if (!container) return null;
    if (scopeLabels.has(container)) return scopeLabels.get(container);
    const kind = dialog ? 'dialog' : 'form';
    const id = container.id;
    let label;
    if (id && !UNSTABLE_ID.test(id)) label = `${kind}#${clean(id, 60)}`;
    else {
      const peers = Array.from(
        container
          .getRootNode()
          .querySelectorAll(dialog ? SCOPE_DIALOG : 'form'),
      );
      label = `${kind}@${peers.indexOf(container) + 1}`;
    }
    scopeLabels.set(container, label);
    return label;
  };

  // The dialog / form `el` acts in (scopeOf's container) holds a fillable control other than `el` itself.
  const scopeHasFields = (el) => {
    const container = el.closest(SCOPE_DIALOG) || el.form || el.closest('form');
    if (!container) return false;
    return Array.from(container.querySelectorAll(FIELD_CONTROLS)).some(
      (control) => control !== el && (typeOf(control) === 'file' || seen(control)),
    );
  };
  // Inside page chrome (a <header> / <footer> / <nav> that is no tablist) - unless that chrome sits inside the
  // element's own form / dialog (Vuetify's `<form>...<footer class="v-footer"><button type=submit>`, a modal's footer
  // with its consent checkbox): then it is the form's own footer. A newsletter <form> inside the page footer stays chrome.
  const inChrome = (el) => {
    const chrome = el.closest('header, footer, nav:not([role=tablist])');
    if (!chrome) return false;
    const container = el.closest(SCOPE_DIALOG) || el.form || el.closest('form');
    return !(container && container !== chrome && container.contains(chrome));
  };
  // An <a> whose href leads somewhere (not "#", not javascript:): a GET, never a form submission.
  const navigatingLink = (el) => {
    const href = (el.getAttribute('href') || '').trim();
    return el.localName === 'a' && !!href && !href.startsWith('#') && !/^javascript:/i.test(href);
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
  // One element per clickable thing: a link / button wrapping exactly one other clickable candidate is ONE target.
  // `<a href><button>` keeps the link (its href is the action); a custom `[role=button]` host around a native
  // <button> / <input> keeps the native one (its type and form). Two copies of one name make {role, name} ambiguous.
  const clickable = (el) =>
    el.localName === 'button' ||
    (el.localName === 'a' && el.hasAttribute('href')) ||
    (el.localName === 'input' &&
      ['submit', 'button', 'image', 'reset'].includes(typeOf(el))) ||
    ['button', 'link'].includes(explicitRole(el));
  const candidateSet = new Set(candidates);
  const nested = new Set();
  for (const el of candidates) {
    if (!clickable(el)) continue;
    const inner = Array.from(el.querySelectorAll('*')).filter((node) =>
      candidateSet.has(node),
    );
    if (inner.length !== 1 || !clickable(inner[0])) continue;
    const native = ['button', 'input'].includes(inner[0].localName);
    const outerNative = ['button', 'input', 'a'].includes(el.localName);
    nested.add(el.localName === 'a' || !native || outerNative ? inner[0] : el);
  }
  const unique = candidates.filter((el) => !nested.has(el));
  const truncated = unique.length > MAX_ELEMENTS;
  const picked = unique.slice(0, MAX_ELEMENTS);

  const described = picked.map((el, index) => {
    const tag = el.localName;
    const type = tag === 'input' ? typeOf(el) : null;
    const role = roleOf(el);
    const isField = el.matches(FIELD_CONTROLS);
    const fieldRoot = fieldRootOf(el, isField);
    const [labelEl, labelOwn] = labelElementOf(el);
    const questionEl = questionElementOf(fieldRoot);
    const question = questionEl ? stripMark(ownText(questionEl)) : '';
    const { name, accessible } = nameOf(
      el,
      role,
      labelEl,
      labelOwn,
      fieldRoot,
      question,
    );
    const selfVisible = seen(el);
    let visible = selfVisible;
    if (!visible && type === 'file') visible = dropzoneOf(el).some(seen);
    else if (
      !visible &&
      (type === 'radio' || type === 'checkbox' || role === 'combobox')
    )
      visible =
        (!!labelEl && seen(labelEl)) || (!!fieldRoot && seen(fieldRoot));
    // A required mark the accessible name hides (stripMark drops a trailing `*` from aria-label / labelledby) or a
    // placeholder carries ("Email *"): frameworks that validate in JS only (Vuetify rules) set no required attribute.
    const markedName = /[*✱]\s*$/.test(
      `${el.getAttribute('aria-label') || ''} ${byIds(el, 'aria-labelledby').map(textOf).join(' ')}`.trim(),
    );
    const markedPlaceholder = /^\s*[*✱]|[*✱]\s*$/.test(
      el.getAttribute('placeholder') || '',
    );
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
    const chooser = choosesFile(el, name, fieldRoot, buttonish, selfVisible);
    const fileTrigger = fileTriggerOf(el, name, buttonish, chooser);
    // Site chrome; a nav that is a tablist (Ashby's Overview | Application) is page content.
    const searchRole =
      type === 'search' || role === 'searchbox' || !!el.closest('[role=search]');
    const searchLike = searchRole || inChrome(el);
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
        // Only something a person answers is required: a link / button inside a required label (Lever's "ATTACH
        // RESUME/CV" anchor around the file input) is not.
        required:
          (isField || !!group || chooser) &&
          (!!el.required ||
            ariaRequired(el) ||
            ariaRequired(fieldRoot) ||
            marksRequired(labelEl) ||
            marksRequired(questionEl) ||
            markedName ||
            markedPlaceholder),
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
        // A custom select trigger that is no text input (a button / div) takes no typing: AriaCombobox only clicks it.
        readonly:
          !!el.readOnly ||
          el.getAttribute('aria-readonly') === 'true' ||
          (group === 'combobox' &&
            !['input', 'textarea'].includes(tag) &&
            !el.isContentEditable),
        visible,
        self_visible: selfVisible,
        in_viewport: visible && inViewport(selfVisible ? el : fieldRoot || el),
        aria_hidden: !!el.closest('[aria-hidden=true]'),
        // aria-describedby text: a field named only by its placeholder is told apart by it (Field signature).
        described_by:
          clean(byIds(el, 'aria-describedby').map(textOf).join(' ')) || null,
        // The field's help text without aria-describedby (Ashby's question-description block beside the label).
        help: helpTextOf(fieldRoot, [questionEl, labelEl], question) || null,
        // Fixed letterless text before a text input ("+380"): Answer::CoerceValue types a phone without that dial code.
        prefix: prefixOf(el, fieldRoot) || null,
        filled,
        group,
        group_key: null,
        password:
          type === 'password' || /(current|new)-password/.test(autocomplete),
        search_like: searchLike,
        submit_like:
          buttonish &&
          !group &&
          !fileTrigger &&
          !fieldRoot &&
          (!searchLike || (isSubmitType(el) && !searchRole)) &&
          (((isSubmitType(el) ||
            SUBMIT_TEXT.test(`${name} ${el.getAttribute('class') || ''}`)) &&
            fieldsNearby(el)) ||
            (
              APPLY_TEXT.test(name) &&
              !navigatingLink(el) &&
              scopeHasFields(el))),
        chooser,
        file_trigger: fileTrigger,
        typeahead: !group && typeaheadLike(el, role),
        captcha_artifact: CAPTCHA_RESPONSE.test(
          el.getAttribute('name') || el.id || '',
        ),
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
        strategies: strategiesOf(el, role, accessible),
        root_strategies: rootStrategiesOf(fieldRoot),
        regions: regionsOf(el, fieldRoot),
        scope: scopeOf(el),
        attrs: {
          id: el.id || null,
          name: el.getAttribute('name'),
          type: el.getAttribute('type'),
          autocomplete: el.getAttribute('autocomplete'),
          placeholder: el.getAttribute('placeholder'),
          accept: el.getAttribute('accept'),
          multiple: el.hasAttribute('multiple'),
          maxlength: el.getAttribute('maxlength'),
          tabindex: el.getAttribute('tabindex'),
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

  // Captcha vendors' frames, by src: [pattern, kind of a frame with that src (null: not a captcha signal)]. A frame
  // that is itself one of them (an hCaptcha enclave / challenge, a reCAPTCHA anchor) is the widget its parent already
  // reported by this rule: it scans nothing, or its own internals (hCaptcha's recaptchacompat g-recaptcha-response
  // shim, its nested challenge iframe) would report the one captcha again, as another vendor.
  const tall = (frame) =>
    seen(frame) && frame.getBoundingClientRect().height > 30;
  const CAPTCHA_FRAMES = [
    [
      /recaptcha\/(api2|enterprise)\/anchor/,
      (frame, src) =>
        /[?&]size=invisible/.test(src) || !seen(frame)
          ? 'recaptcha_invisible'
          : 'recaptcha',
    ],
    [
      /recaptcha\/(api2|enterprise)\/bframe/,
      (frame) => (seen(frame) ? 'recaptcha_challenge' : null),
    ],
    [/hcaptcha/, (frame) => (tall(frame) ? 'hcaptcha' : 'hcaptcha_invisible')],
    [
      /challenges\.cloudflare\.com/,
      (frame) => (tall(frame) ? 'turnstile' : 'turnstile_invisible'),
    ],
    [/captcha-delivery\.com/, () => 'datadome'],
  ];
  const captchaFrame = (src) =>
    CAPTCHA_FRAMES.find(([pattern]) => pattern.test(src));
  const captcha = [];
  const addCaptcha = (kind) =>
    !kind || captcha.includes(kind) || captcha.push(kind);
  if (!captchaFrame(location.href)) {
    for (const frame of doc.querySelectorAll('iframe')) {
      const src = frame.src || '';
      const rule = captchaFrame(src);
      if (rule) addCaptcha(rule[1](frame, src));
    }
    if (doc.querySelector('.grecaptcha-badge'))
      addCaptcha('recaptcha_invisible');
    // An invisible captcha the page frames only on submit (Lever's hCaptcha): its widget div, response field or script.
    const unframed = [
      ['hcaptcha', '.h-captcha[data-sitekey], script[src*="hcaptcha.com"]'],
      ['recaptcha', '.g-recaptcha[data-sitekey], script[src*="recaptcha/"]'],
      ['turnstile', '.cf-turnstile[data-sitekey]'],
    ];
    for (const [kind, selector] of unframed) {
      if (captcha.some((found) => found.startsWith(kind))) continue;
      const response = Array.from(doc.querySelectorAll('input, textarea')).some(
        (field) =>
          CAPTCHA_RESPONSE.test(field.getAttribute('name') || field.id || '') &&
          (field.getAttribute('name') || field.id)
            .toLowerCase()
            .startsWith(
              kind === 'hcaptcha' ? 'h-' : kind === 'recaptcha' ? 'g-' : 'cf-',
            ),
      );
      if (response || doc.querySelector(selector))
        addCaptcha(`${kind}_invisible`);
    }
  }

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
