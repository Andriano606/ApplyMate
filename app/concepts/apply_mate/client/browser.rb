# frozen_string_literal: true

class ApplyMate::Client::Browser
  USER_AGENT = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'

  # Injected before every page load to mask the CDP automation markers that
  # reCAPTCHA, Cloudflare Turnstile, and similar bot-detection scripts inspect.
  # Covers the signals from the Cloudflare-bypass guide: webdriver, plugins,
  # languages, hardwareConcurrency, deviceMemory, WebGL vendor/renderer, window.chrome.
  STEALTH_SCRIPT = <<~JS.freeze
    Object.defineProperty(navigator, 'webdriver',           { get: () => undefined });
    Object.defineProperty(navigator, 'plugins',             { get: () => [{ name: 'PDF Viewer' }, { name: 'Chrome PDF Viewer' }] });
    Object.defineProperty(navigator, 'languages',           { get: () => ['uk-UA', 'uk', 'en-US', 'en'] });
    Object.defineProperty(navigator, 'hardwareConcurrency', { get: () => 8 });
    Object.defineProperty(navigator, 'deviceMemory',        { get: () => 8 });
    if (!window.chrome) window.chrome = { runtime: {}, loadTimes: function() {}, csi: function() {}, app: {} };
    const __getParameter = WebGLRenderingContext.prototype.getParameter;
    WebGLRenderingContext.prototype.getParameter = function(p) {
      if (p === 37445) return 'Google Inc. (Intel)';
      if (p === 37446) return 'ANGLE (Intel, Intel(R) UHD Graphics, OpenGL 4.1)';
      return __getParameter.call(this, p);
    };
  JS

  CHALLENGE_POLLS = 6 # how many times to re-check while the challenge solves
  CHALLENGE_WAIT  = 3 # seconds between checks (≈18s total budget)

  Response = ApplyMate::Client::Response

  # Real Chrome, in the order a Linux host tends to have it. CHROME_PATH wins,
  # so a machine with an unusual install (or the container) can say so.
  CHROME_CANDIDATES = %w[
    /usr/bin/google-chrome-stable
    /usr/bin/google-chrome
    /opt/google/chrome/chrome
  ].freeze

  def self.chrome_path
    return @chrome_path if defined?(@chrome_path)

    @chrome_path = ENV['CHROME_PATH'].presence || CHROME_CANDIDATES.find { |candidate| File.executable?(candidate) }
  end

  # proxy: optional proxy URL string ("http://host:port" / "socks5://host:port").
  # Routes Chrome through it so Cloudflare-protected sites see the proxy IP while a
  # real browser solves the JS challenge that the raw HTTP client cannot.
  # profile: a name ("dou") to browse with a profile that outlives this session —
  # cookies, storage and a solved Cloudflare challenge are kept, which is what
  # makes the next visit look like a returning visitor rather than a fresh
  # install. Omit it for the throwaway profile every automated flow used before.
  def initialize(headless: true, proxy: nil, profile: nil)
    @profile = profile && ApplyMate::Client::BrowserProfile.acquire(profile)

    @browser = Ferrum::Browser.new(
      window_size: [ 1920, 1080 ],
      process_timeout: 20,
      headless: headless,
      **browser_path_option,
      **proxy_option(proxy),
      browser_options: {
        **profile_option,
        # Chrome's sandbox needs unprivileged user namespaces, which the staging
        # host (Raspberry Pi) blocks via AppArmor. Without these flags Chrome dies
        # on boot with "No usable sandbox!" and never exposes its CDP websocket.
        'no-sandbox': nil,
        # /dev/shm is only 64M inside the container — keep Chrome off it.
        'disable-dev-shm-usage': nil,
        'disable-blink-features': 'AutomationControlled',
        # Helps when Cloudflare Turnstile renders inside a cross-origin frame.
        'disable-features': 'IsolateOrigins,site-per-process',
        'user-agent': USER_AGENT
      }
    )

    restore_cookies
  end

  # Drop-in replacement for ApplyMate::Client::AsyncHttp#get for Cloudflare-protected
  # GET pages: navigates with a real browser, solving the "Just a moment…" JS
  # challenge (reloading a few times to let it clear), and returns a Response whose
  # #body is the rendered HTML. status is 200 once the challenge clears, 403 if it
  # never does. Scrapers that only read response.body (e.g. Dou#fetch_description)
  # can use a Browser instance as their client unchanged. NOTE: #post is unsupported.
  def get(url, headers: {}, **)
    page = new_page
    page.headers.set(headers) if headers.present?
    body    = load_past_cloudflare(page, url)
    cleared = !cloudflare_challenge?(body)
    cookies = @browser.cookies.all.map { |_, c| "#{c.name}=#{c.value}" }
    Response.new(body, { 'set-cookie' => cookies }, cleared ? 200 : 403, current_url(page) || url)
  ensure
    page&.close
  end

  # Page lifecycle contract: fetch_rendered and click_and_fetch open AND close @page
  # in their own ensure blocks (fire-and-forget helpers). navigate_to opens @page but
  # does NOT close it — the caller owns the lifetime and must call quit when done.
  # Never mix both patterns on the same Browser instance.

  # Navigates to url, executes JS, and returns [final_url, body, cookies_string].
  # Unlike the HTTP clients, does not reject redirected URLs — use for external
  # pages that may redirect or require JS rendering (Vue/React apps).
  def fetch_rendered(url)
    navigate_to(url)
    cookies = @browser.cookies.all.map { |_, c| "#{c.name}=#{c.value}" }.join('; ')
    [ @page.current_url, @page.body, cookies ]
  rescue StandardError => e
    Rails.logger.error "ApplyMate::Client::Browser Error: #{e.message}"
    raise e
  ensure
    @page&.close
  end

  # Navigates to url, clicks the first visible element matching selector, waits
  # for network idle, then returns [final_url, body, cookies_string, unique_selector].
  # unique_selector is a deterministic CSS path for the exact element clicked,
  # safe to reuse on subsequent loads of the same page.
  def click_and_fetch(url, selector)
    navigate_to(url)
    unique_selector = click_first_visible_with_unique_path(selector)
    raise "Trigger element not found or not visible: #{selector}" unless unique_selector
    wait_for_idle
    cookies = @browser.cookies.all.map { |_, c| "#{c.name}=#{c.value}" }.join('; ')
    [ @page.current_url, @page.body, cookies, unique_selector ]
  rescue StandardError => e
    Rails.logger.error "ApplyMate::Client::Browser Error: #{e.message}"
    raise e
  ensure
    @page&.close
  end

  # Opens a new page and navigates to url. Does not close the page — caller owns
  # the lifecycle and must call quit when done.
  def navigate_to(url)
    @page = new_page
    @page.goto(url)
  rescue Ferrum::PendingConnectionsError
    # ignore pending third-party requests (trackers, analytics)
  ensure
    wait_for_idle
  end

  def body
    @page.body
  end

  # page defaults to the live one; the Cloudflare path passes its own, which it
  # holds before @page is assigned. Nil rather than raising: a URL we cannot read
  # is never worth aborting navigation for.
  def current_url(page = @page)
    page&.current_url
  rescue StandardError
    nil
  end

  # Sources of every iframe on the page — used to follow embedded ATS forms,
  # whose contents are invisible to the parent document (cross-origin).
  def iframe_sources
    @page.evaluate(<<~JS)
      Array.from(document.querySelectorAll('iframe'))
        .map(function(f) { return f.src })
        .filter(function(src) { return src && src.indexOf('http') === 0 })
    JS
  end

  # Selects whatever the focused field holds so the next keystrokes replace it.
  # Never fatal: an empty field (the usual case) needs no clearing at all.
  def clear_field
    @page.keyboard.type([ :ctrl, 'a' ])
  rescue StandardError => e
    Rails.logger.debug { "Browser: could not clear field before typing: #{e.message}" }
  end

  # Polls the dropdown a combobox opens and marks the best match for clicking:
  # exact text first, then a partial match either way (the answer may be broader
  # or narrower than the option's wording).
  def wait_for_option(value, timeout: 4)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout

    loop do
      chosen = @page.evaluate(<<~JS)
        (function(wanted) {
          var opts = Array.from(document.querySelectorAll('[role="option"]'))
            .filter(function(o){ var cs = window.getComputedStyle(o); return cs.display !== 'none' && cs.visibility !== 'hidden'; });
          if (!opts.length) return null;
          var norm = function(s){ return (s || '').replace(/\\s+/g, ' ').trim().toLowerCase(); };
          var w = norm(wanted);
          var hit = opts.find(function(o){ return norm(o.textContent) === w; }) ||
                    (w ? opts.find(function(o){ return norm(o.textContent).indexOf(w) !== -1; }) : null) ||
                    (w ? opts.find(function(o){ return w.indexOf(norm(o.textContent)) !== -1; }) : null);
          if (!hit) return null;
          hit.setAttribute('data-am-option', '1');
          return (hit.textContent || '').replace(/\\s+/g, ' ').trim();
        })(#{value.to_s.to_json})
      JS
      return chosen if chosen.present?
      return nil if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.25
    end
  end

  # Waits until the page actually renders a field. Network idle is not enough:
  # an SPA (Ashby, Vue/React careers pages) finishes its requests and only then
  # paints the form, so judging "this page has no form" right after navigation
  # is a race — one that reported a perfectly good form as missing.
  # Returns true if fields appeared, false on timeout (a genuinely fieldless page).
  def wait_for_fields(timeout: 10)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout

    loop do
      return true if field_count.positive?
      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.25
    end
  rescue StandardError
    false
  end

  # Number of fillable fields visible on the page — zero means the form is not
  # in this document (embedded elsewhere or not rendered yet).
  def field_count
    @page.evaluate(<<~JS)
      document.querySelectorAll(
        'input:not([type="hidden"]):not([type="submit"]):not([type="button"]), textarea, select'
      ).length
    JS
  end

  def screenshot
    @page.screenshot(encoding: :binary)
  end

  # True while the underlying Chrome process is reachable. Used by operations to
  # decide between reusing a live session and re-navigating from scratch.
  def alive?
    # A real CDP round-trip — attribute checks can't detect a dead Chrome process.
    @page.present? && @page.evaluate('true') == true
  rescue StandardError
    false
  end

  # Shared JS helpers injected into snapshot_fields and page_digest evaluations.
  DOM_HELPERS_JS = <<~JS.freeze
    function amVisible(el) {
      var node = el;
      while (node && node !== document.documentElement) {
        var cs = window.getComputedStyle(node);
        if (cs.display === 'none' || cs.visibility === 'hidden') return false;
        node = node.parentElement;
      }
      return true;
    }

    // Simplified accname: aria-labelledby > aria-label > label[for] > wrapping label > placeholder
    function amAccessibleName(el) {
      var refs = el.getAttribute('aria-labelledby');
      if (refs) {
        var text = refs.split(/\\s+/).map(function(id) {
          var n = document.getElementById(id);
          return n ? n.textContent.trim() : '';
        }).filter(Boolean).join(' ');
        if (text) return text;
      }
      if (el.getAttribute('aria-label')) return el.getAttribute('aria-label').trim();
      if (el.labels && el.labels.length) return el.labels[0].textContent.trim();
      var node = el.parentElement;
      while (node && node.tagName !== 'FORM' && node !== document.body) {
        if (node.tagName === 'LABEL') return node.textContent.trim();
        node = node.parentElement;
      }
      // Widget libraries render the question as a sibling <label>/heading with no
      // "for" attribute (Ashby's comboboxes) — the placeholder would otherwise
      // become the field's name ("Start typing...").
      var nearby = amNearbyLabel(el);
      if (nearby) return nearby;
      return el.placeholder ? el.placeholder.trim() : '';
    }

    // Question text of the block wrapping exactly this one control. Walks up a
    // few levels and stops as soon as the block holds another field, so a label
    // is never stolen from a neighbouring question.
    function amNearbyLabel(el) {
      var node = el.parentElement;
      for (var depth = 0; node && depth < 4 && node !== document.body; depth++) {
        var fields = node.querySelectorAll('input:not([type="hidden"]), textarea, select');
        if (fields.length > 1) return '';
        var labelNode = node.querySelector('label, legend, h1, h2, h3, h4, h5, h6');
        if (labelNode) {
          var text = (labelNode.textContent || '').replace(/\\s+/g, ' ').trim();
          if (text && text.length < 200) return text;
        }
        node = node.parentElement;
      }
      return '';
    }

    // Shared question of a radio/checkbox group: the label of the closest block
    // that contains every option, so the merged field reads "Which of the
    // following best describes your gender identity?" and not "Woman".
    function amGroupLabel(el, groupName) {
      if (!groupName) return '';
      var node = el.parentElement;
      for (var depth = 0; node && depth < 6 && node !== document.body; depth++) {
        var members = node.querySelectorAll('[name="' + (window.CSS && CSS.escape ? CSS.escape(groupName) : groupName) + '"]');
        if (members.length > 1) {
          var labelNode = node.querySelector('legend, label, h1, h2, h3, h4, h5, h6');
          if (labelNode) {
            var text = (labelNode.textContent || '').replace(/\\s+/g, ' ').trim();
            if (text && text.length < 200) return text;
          }
        }
        node = node.parentElement;
      }
      return '';
    }

    function amCssSelector(el) {
      var id = el.id || '';
      if (id) return /^[\\w-]+$/.test(id) ? '#' + id : '[id="' + id + '"]';
      if (el.name) return '[name="' + el.name + '"]';
      if (el.placeholder) return '[placeholder="' + el.placeholder + '"]';
      return el.tagName.toLowerCase();
    }

    // Deterministic unique CSS path — same algorithm as the trigger-click helper.
    function amUniquePath(el) {
      if (el.id && /^[\\w-]+$/.test(el.id)) return '#' + CSS.escape(el.id);
      var parts = [];
      var node = el;
      while (node && node.parentElement) {
        var tag = node.tagName.toLowerCase();
        var par = node.parentElement;
        var siblings = Array.from(par.children).filter(function(c) { return c.tagName === node.tagName; });
        parts.unshift(siblings.length > 1 ? tag + ':nth-of-type(' + (siblings.indexOf(node) + 1) + ')' : tag);
        if (par.id && /^[\\w-]+$/.test(par.id)) {
          parts.unshift('#' + CSS.escape(par.id));
          return parts.join(' > ');
        }
        if (par === document.body) break;
        node = par;
      }
      return parts.join(' > ');
    }

    var AM_FIELD_SELECTOR = 'input, textarea, select, ' +
      '[role="textbox"], [role="combobox"], [role="searchbox"], [role="listbox"], ' +
      '[role="checkbox"], [role="radio"], [contenteditable="true"], [contenteditable=""]';
  JS

  # Walks visible fields inside scope_selector (or the whole document), stamps each
  # with data-am-field="<i>" — a handle stable for the lifetime of this page — and
  # returns { 'fields' => [...], 'submit' => {...} | nil }.
  # Fields follow the IR shape (see Apply model form_data comment): name/tag/type/
  # accessible_name (+ label alias)/placeholder/required/autocomplete/fieldset/
  # position/value/options plus live-session keys handle/selector/form_index.
  # Covers native inputs and custom widgets (role=textbox/combobox/…, contenteditable).
  # Handles survive SPA re-renders of attribute values (id/class), but not node
  # replacement — callers must treat a failed handle lookup as a lost session.
  def snapshot_fields(scope_selector: nil)
    @page.evaluate(<<~JS)
      (function() {
        #{DOM_HELPERS_JS}
        var scope = #{scope_selector.present? ? "document.querySelector(#{scope_selector.to_json})" : 'null'} || document;

        // Clear stale stamps from previous snapshots — hidden elements keep
        // their old data-am-field and would shadow fresh handles on re-renders.
        document.querySelectorAll('[data-am-field]').forEach(function(el) {
          el.removeAttribute('data-am-field');
        });

        var els = Array.from(scope.querySelectorAll(AM_FIELD_SELECTOR));
        var fields = [], idx = 0;

        els.forEach(function(el) {
          var tag    = el.tagName.toLowerCase();
          var native = ['input', 'textarea', 'select'].includes(tag);
          var type;
          if (native) {
            type = tag === 'input' ? (el.getAttribute('type') || 'text').toLowerCase() : tag;
          } else {
            type = (el.getAttribute('role') || 'textbox').toLowerCase();
          }
          if (['submit', 'button', 'image', 'reset'].includes(type)) return;
          // Hidden inputs carry tokens the form needs, and a file input is
          // routinely display:none behind a styled dropzone — we attach to it
          // through DataTransfer, which does not care whether it is on screen.
          // Everything else must be visible to count.
          if (type !== 'hidden' && type !== 'file' && !amVisible(el)) return;

          // An autocomplete input ignores a written value — it tracks a chosen
          // option, so it must be filled by typing and picking from the list.
          if (native && el.getAttribute('role') === 'combobox' ||
              el.getAttribute('aria-autocomplete') === 'list') {
            type = 'combobox';
          }

          var accName = amAccessibleName(el);
          var name    = (el.name || el.id || el.placeholder || accName || '').trim();
          if (!name) return;

          el.setAttribute('data-am-field', String(idx));

          var entry = {
            handle:          idx,
            name:            name,
            selector:        amCssSelector(el),
            form_index:      idx,
            position:        idx,
            tag:             tag,
            type:            type,
            accessible_name: accName,
            label:           accName,
            placeholder:     el.placeholder || '',
            required:        !!(el.required || el.getAttribute('aria-required') === 'true' || accName.indexOf('*') !== -1),
            autocomplete:    el.getAttribute('autocomplete') || '',
            fieldset:        '',
            value:           native ? (el.value || '') : el.textContent.trim()
          };

          var fs = el.closest('fieldset');
          if (fs) {
            var legend = fs.querySelector('legend');
            entry.fieldset = legend ? legend.textContent.trim() : '';
          }

          if (tag === 'select') {
            entry.options = Array.from(el.options).map(function(o) {
              return { label: o.textContent.trim(), value: o.value };
            });
            var sel = el.querySelector('option[selected]');
            entry.value = sel ? sel.value : '';
          }

          if (type === 'radio' || type === 'checkbox') {
            // Each option keeps its own handle so a merged group can be answered
            // by clicking the right member — setting a value on a radio does
            // nothing at all.
            entry.options = [{
              label:  (accName || el.id || el.value || '').toString(),
              value:  el.value || '',
              handle: idx
            }];
            entry.group_label = amGroupLabel(el, el.name);
          }

          idx += 1;
          fields.push(entry);
        });

        // Choice questions built from plain buttons (Ashby's Yes/No toggles):
        // no input, no name, no ARIA role — invisible to every selector above,
        // so the question would silently vanish from the form. Each option gets
        // its own handle; answering means clicking one.
        var groupIdx = 0;
        var actionWording = /submit|apply|upload|drag|next|back|continue|cancel|close|sign|log/i;
        Array.from(scope.querySelectorAll('div, fieldset, span')).forEach(function(box) {
          var options = Array.from(box.children).filter(function(child) {
            if (child.tagName !== 'BUTTON' && child.getAttribute('role') !== 'button') return false;
            var text = (child.textContent || '').replace(/\\s+/g, ' ').trim();
            return text.length > 0 && text.length <= 40 && !actionWording.test(text) && amVisible(child);
          });
          if (options.length < 2) return;
          // A VISIBLE field inside means this is a layout wrapper, not a choice
          // group. The widget's own state holder (Ashby keeps a hidden checkbox
          // behind the Yes/No buttons) is invisible and must not disqualify it.
          var visibleFields = Array.from(
            box.querySelectorAll('input:not([type="hidden"]), textarea, select')
          ).filter(amVisible);
          if (visibleFields.length > 0) return;
          if (box.getAttribute('data-am-group')) return;

          box.setAttribute('data-am-group', String(groupIdx));
          var entry = {
            handle:          'grp-' + groupIdx,
            name:            '',
            selector:        '[data-am-group="' + groupIdx + '"]',
            form_index:      idx,
            position:        idx,
            tag:             'buttongroup',
            type:            'button_group',
            accessible_name: amNearbyLabel(options[0]) || amGroupLabel(box, null),
            label:           '',
            placeholder:     '',
            required:        false,
            autocomplete:    '',
            fieldset:        '',
            value:           '',
            options:         options.map(function(opt, i) {
              var text = (opt.textContent || '').replace(/\\s+/g, ' ').trim();
              opt.setAttribute('data-am-field', 'opt-' + groupIdx + '-' + i);
              return { label: text, value: text, handle: 'opt-' + groupIdx + '-' + i };
            })
          };
          entry.label = entry.accessible_name;
          entry.name  = entry.accessible_name || ('choice_' + groupIdx);
          groupIdx += 1;
          idx += 1;
          fields.push(entry);
        });

        // Modern ATS forms (Ashby, many SPAs) render no <form> tag and no
        // type="submit" — fall back to a visible button whose text says submit.
        function amFindSubmit(root) {
          var typed = root.querySelector('button[type="submit"], input[type="submit"]');
          if (typed) return typed;
          var wording = /submit|apply|send|надісл|відгук|застосув|подати|откликн|отправ/i;
          return Array.from(root.querySelectorAll('button, [role="button"], input[type="button"]'))
            .filter(amVisible)
            .find(function(b) { return wording.test((b.textContent || b.value || '').trim()); }) || null;
        }

        var submitEl = amFindSubmit(scope) ||
                       (scope !== document ? amFindSubmit(document) : null);
        var submit = null;
        if (submitEl) {
          submitEl.setAttribute('data-am-field', 'submit');
          submit = { handle: 'submit', text: (submitEl.textContent || submitEl.value || '').trim(), selector: amCssSelector(submitEl) };
        }

        return { fields: fields, submit: submit };
      })()
    JS
  end

  # Full page observation for the External::Generic loop: re-snapshots fields
  # (fresh data-am-field handles), stamps visible buttons (btn-<i> handles),
  # collects alert/status texts and per-field validation errors, and reports
  # blocker signals (captcha widgets, password fields). Cheap and deterministic —
  # called once per loop iteration.
  def observe_state(scope_selector: nil)
    snapshot = snapshot_fields(scope_selector: scope_selector)
    extras   = @page.evaluate(<<~JS)
      (function() {
        #{DOM_HELPERS_JS}

        var buttons = Array.from(document.querySelectorAll('button, input[type="submit"], input[type="button"], [role="button"]'))
          .filter(amVisible).slice(0, 30)
          .map(function(b, i) {
            // snapshot_fields already stamped the submit button — keep its handle
            var handle = b.getAttribute('data-am-field') === 'submit' ? 'submit' : 'btn-' + i;
            if (handle !== 'submit') b.setAttribute('data-am-field', handle);
            return { handle: handle, text: (b.textContent || b.value || '').replace(/\\s+/g, ' ').trim().slice(0, 80) };
          })
          .filter(function(b) { return b.text.length > 0; });

        var alerts = Array.from(document.querySelectorAll('[role="alert"], [role="status"], .alert, .flash, .notification'))
          .filter(amVisible)
          .map(function(a) { return a.textContent.replace(/\\s+/g, ' ').trim(); })
          .filter(Boolean).slice(0, 10);

        var errors = Array.from(document.querySelectorAll('[aria-invalid="true"], .field_with_errors input, .has-error input, input.error, textarea.error'))
          .filter(amVisible).slice(0, 20)
          .map(function(el) {
            var msgNode = el.closest('div, fieldset, li');
            var msg = '';
            if (msgNode) {
              var m = msgNode.querySelector('[class*="error"], [role="alert"]');
              if (m) msg = m.textContent.replace(/\\s+/g, ' ').trim().slice(0, 160);
            }
            return { handle: el.getAttribute('data-am-field'), name: el.name || el.id || '', message: msg };
          });

        // Only a VISIBLE challenge counts — invisible reCAPTCHA v3 iframes are
        // handled by attempt_recaptcha_refresh and must not block the flow.
        var captcha = Array.from(document.querySelectorAll('iframe[src*="recaptcha"], iframe[src*="hcaptcha"]'))
          .filter(amVisible).length > 0 ||
          !!document.querySelector('.g-recaptcha[data-size="normal"], .h-captcha');
        var passwordField = !!Array.from(document.querySelectorAll('input[type="password"]')).filter(amVisible).length;

        return {
          url:          location.href,
          buttons:      buttons,
          alerts:       alerts,
          errors:       errors,
          form_present: !!document.querySelector('form input, form textarea, form select, [data-am-field]'),
          captcha:      captcha,
          password_field: passwordField
        };
      })()
    JS
    extras.merge('fields' => snapshot['fields'], 'submit' => snapshot['submit'])
  end

  # Compact structured snapshot of the page for AI navigation (CheckFormPage) —
  # replaces sending minimized HTML. Every element comes with a deterministic
  # uniquePath selector, so the AI only PICKS a selector from the digest and
  # never invents one. Hidden forms/buttons are included with hidden: true
  # (SPA apps keep them in the DOM until a trigger click reveals them).
  def page_digest
    @page.evaluate(<<~JS)
      (function() {
        #{DOM_HELPERS_JS}

        function trimText(s, max) {
          s = (s || '').replace(/\\s+/g, ' ').trim();
          return s.length > max ? s.slice(0, max) + '…' : s;
        }

        var headings = Array.from(document.querySelectorAll('h1, h2, h3, h4, h5, h6'))
          .filter(amVisible).slice(0, 15)
          .map(function(h) { return { level: h.tagName.toLowerCase(), text: trimText(h.textContent, 120) }; });

        var forms = Array.from(document.querySelectorAll('form')).slice(0, 10).map(function(f) {
          var fieldEls = Array.from(f.querySelectorAll(AM_FIELD_SELECTOR));
          var names = fieldEls.map(function(el) {
            var type = el.tagName === 'INPUT' ? (el.getAttribute('type') || 'text').toLowerCase() : '';
            if (['submit', 'button', 'image', 'reset', 'hidden'].includes(type)) return null;
            return trimText(el.name || el.id || el.placeholder || amAccessibleName(el), 60);
          }).filter(Boolean).slice(0, 20);
          var submitEl = f.querySelector('button[type="submit"], input[type="submit"]');
          return {
            selector:    amUniquePath(f),
            hidden:      !amVisible(f),
            field_names: names,
            submit_text: submitEl ? trimText(submitEl.textContent || submitEl.value, 60) : ''
          };
        });

        // SPA pages often have fields without a <form> tag — offer their nearest
        // common ancestor as a form-container candidate.
        var container = null;
        if (forms.length === 0) {
          var fieldEls = Array.from(document.querySelectorAll(AM_FIELD_SELECTOR)).filter(amVisible);
          if (fieldEls.length > 0) {
            var anc = fieldEls[0];
            outer: while (anc && anc !== document.body) {
              for (var i = 1; i < fieldEls.length; i++) {
                if (!anc.contains(fieldEls[i])) { anc = anc.parentElement; continue outer; }
              }
              break;
            }
            if (anc && anc !== document.body) {
              container = {
                selector:    amUniquePath(anc),
                field_names: fieldEls.map(function(el) {
                  return trimText(el.name || el.id || el.placeholder || amAccessibleName(el), 60);
                }).filter(Boolean).slice(0, 20)
              };
            }
          }
        }

        var buttons = Array.from(document.querySelectorAll('button, input[type="submit"], input[type="button"], [role="button"]'))
          .slice(0, 40)
          .map(function(b) {
            var text = trimText(b.textContent || b.value, 80);
            if (!text) return null;
            return { selector: amUniquePath(b), text: text, hidden: !amVisible(b) };
          }).filter(Boolean);

        var links = Array.from(document.querySelectorAll('a[href]'))
          .filter(function(a) {
            var href = a.getAttribute('href') || '';
            return amVisible(a) && href && href[0] !== '#' && href.indexOf('javascript:') !== 0;
          })
          .slice(0, 60)
          .map(function(a) {
            var text = trimText(a.textContent, 80);
            if (!text) return null;
            return { selector: amUniquePath(a), text: text, href: a.href };
          }).filter(Boolean);

        return {
          title:           document.title,
          url:             location.href,
          headings:        headings,
          forms:           forms,
          fields_container: container,
          buttons:         buttons,
          links:           links
        };
      })()
    JS
  end

  # Fills the field stamped by snapshot_fields via its handle, triggering
  # Vue/React reactivity the same way fill_field does.
  def fill_by_handle(handle, value, tag)
    proto = tag == 'textarea' ? 'HTMLTextAreaElement' : 'HTMLInputElement'
    @page.execute(<<~JS)
      (function() {
        var el = document.querySelector('[data-am-field="' + #{handle.to_s.to_json} + '"]');
        if (!el) return;
        if (el.tagName === 'SELECT') {
          el.value = #{value.to_json};
        } else {
          var desc = Object.getOwnPropertyDescriptor(#{proto}.prototype, 'value');
          if (desc && desc.set) { desc.set.call(el, #{value.to_json}); } else { el.value = #{value.to_json}; }
        }
        el.dispatchEvent(new Event('input',  { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
      })()
    JS
  end

  # Types into a field the way a person does: focus, select what is there, then
  # let the browser generate the input. Values written straight into the DOM are
  # visible and even reach React's state, yet form libraries that track their own
  # store from trusted events treat such a field as untouched — which is how a
  # filled-in email still came back as "missing entry" on submit.
  # Returns false when the field cannot be reached, so callers can fall back.
  def type_by_handle(handle, value)
    node = @page.at_css(%([data-am-field="#{handle}"]))
    return false if node.nil?

    node.focus
    clear_field
    @page.command('Input.insertText', text: value.to_s)
    true
  rescue StandardError => e
    Rails.logger.warn("Browser: typing into #{handle} failed: #{e.message}")
    false
  end

  # Real mouse click on a stamped element (checkbox, radio, option, button).
  # Same reason as type_by_handle: a synthetic click is ignored by forms that
  # only trust browser-generated events.
  def click_element_by_handle(handle)
    node = @page.at_css(%([data-am-field="#{handle}"]))
    return false if node.nil?

    node.scroll_into_view
    node.click
    true
  rescue StandardError => e
    Rails.logger.warn("Browser: clicking #{handle} failed: #{e.message}")
    false
  end

  # Fills an autocomplete: types the text with real keystrokes so the widget
  # filters its list, then clicks the matching option. Writing the value alone
  # leaves such a field "empty" for the site, which rejects it as unanswered.
  # Returns the chosen option's text, or nil when nothing matched.
  def select_from_combobox(handle, value)
    node = @page.at_css(%([data-am-field="#{handle}"]))
    return nil if node.nil?

    node.focus
    clear_field
    @page.keyboard.type(value.to_s)

    chosen = wait_for_option(value)
    return nil if chosen.blank?

    option = @page.at_css('[data-am-option="1"]')
    return nil if option.nil?

    option.click
    @page.evaluate("document.querySelectorAll('[data-am-option]').forEach(function(e){e.removeAttribute('data-am-option')})")
    chosen
  rescue StandardError => e
    Rails.logger.warn("Browser: combobox selection failed: #{e.message}")
    nil
  end

  # Current state of a stamped checkbox — lets callers click only when the box
  # is not already in the wanted state, and verify that a click landed.
  def checkbox_checked?(handle)
    @page.evaluate(<<~JS)
      (function() {
        var el = document.querySelector('[data-am-field="' + #{handle.to_s.to_json} + '"]');
        return el ? !!el.checked : false;
      })()
    JS
  rescue StandardError
    false
  end

  # Checks or unchecks the checkbox stamped with the given handle. A checkbox is
  # driven by its `checked` property — writing `value` (what fill_by_handle does)
  # leaves it untouched, which silently skips required consent boxes.
  def set_checkbox_by_handle(handle, checked)
    @page.execute(<<~JS)
      (function() {
        var el = document.querySelector('[data-am-field="' + #{handle.to_s.to_json} + '"]');
        if (!el) return;
        var desired = #{checked ? 'true' : 'false'};
        if (el.checked !== desired) {
          var desc = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'checked');
          if (desc && desc.set) { desc.set.call(el, desired); } else { el.checked = desired; }
          el.dispatchEvent(new Event('click',  { bubbles: true }));
          el.dispatchEvent(new Event('input',  { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
        }
      })()
    JS
  end

  # Attaches the file at path to the field stamped with the given handle.
  # Same DataTransfer technique as attach_file (works with remote Chrome).
  def attach_file_by_handle(handle, path)
    data     = Base64.strict_encode64(File.binread(path))
    filename = File.basename(path)
    @page.evaluate(<<~JS)
      (function() {
        var el = document.querySelector('[data-am-field="' + #{handle.to_s.to_json} + '"]');
        if (!el) return false;
        var binary = atob(#{data.to_json});
        var bytes  = new Uint8Array(binary.length);
        for (var i = 0; i < binary.length; i++) { bytes[i] = binary.charCodeAt(i); }
        var dt = new DataTransfer();
        dt.items.add(new File([bytes], #{filename.to_json}, { type: 'application/pdf' }));
        el.files = dt.files;
        el.dispatchEvent(new Event('change', { bubbles: true }));
        el.dispatchEvent(new Event('input',  { bubbles: true }));
        return true;
      })()
    JS
  rescue StandardError => e
    Rails.logger.error "ApplyMate::Client::Browser attach by handle failed: #{e.message}"
    false
  end

  # Clicks the element stamped with the given handle (usually the submit button).
  # Returns true if the element was found and clicked.
  def click_by_handle(handle)
    @page.evaluate(<<~JS)
      (function() {
        var el = document.querySelector('[data-am-field="' + #{handle.to_s.to_json} + '"]');
        if (!el) return false;
        el.scrollIntoView({ behavior: 'instant', block: 'center' });
        el.click();
        return true;
      })()
    JS
  end

  # Finds the first visible element matching selector and clicks it.
  # Narrows to elements whose text contains text (case-insensitive) when provided.
  # Returns true if clicked, false if nothing matched.
  def click(selector, text: nil)
    @page.evaluate(<<~JS)
      (function() {
        var all  = Array.from(document.querySelectorAll(#{selector.to_json}));
        var text = #{text.present? ? text.downcase.to_json : 'null'};
        var els  = text
          ? all.filter(function(el) { return el.textContent.trim().toLowerCase().indexOf(text) !== -1; })
          : all;
        if (els.length === 0) els = all;
        for (var i = 0; i < els.length; i++) {
          var el = els[i], node = el, visible = true;
          while (node && node !== document.documentElement) {
            var cs = window.getComputedStyle(node);
            if (cs.display === 'none' || cs.visibility === 'hidden') { visible = false; break; }
            node = node.parentElement;
          }
          if (visible) {
            el.scrollIntoView({ behavior: 'instant', block: 'center' });
            el.click();
            return true;
          }
        }
        return false;
      })()
    JS
  end

  # Sets a form field value in a way that triggers Vue/React reactivity
  # (native property setter + input/change events).
  # Falls back to positional lookup (form_index) when the selector finds nothing —
  # needed for Vue/React apps that assign random IDs like `input-33` on each load.
  def fill_field(selector, value, tag, form_index: nil)
    proto    = tag == 'textarea' ? 'HTMLTextAreaElement' : 'HTMLInputElement'
    index_js = form_index.nil? ? 'null' : form_index.to_s
    @page.execute(<<~JS)
      (function() {
        var el = #{selector.present? ? "document.querySelector(#{selector.to_json})" : 'null'};
        if (!el && #{index_js} !== null) {
          var all = document.querySelectorAll(
            'form input:not([type="submit"]):not([type="button"]):not([type="image"]):not([type="reset"]), ' +
            'form textarea, form select'
          );
          el = all[#{index_js}] || null;
        }
        if (!el) return;
        var desc = Object.getOwnPropertyDescriptor(#{proto}.prototype, 'value');
        if (desc && desc.set) {
          desc.set.call(el, #{value.to_json});
        } else {
          el.value = #{value.to_json};
        }
        el.dispatchEvent(new Event('input',  { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
      })()
    JS
  end

  # Attaches cv_path to the file input by encoding the file in Ruby and injecting it
  # into the browser via DataTransfer. DOM.setFileInputFiles requires Chrome to access
  # the path on its own filesystem, which fails when Chrome runs in a separate container.
  # Tries selectors in priority order: stored selector, generic file type, then form_index.
  def attach_file(file_input, cv_path)
    cv_data   = Base64.strict_encode64(File.binread(cv_path))
    filename  = File.basename(cv_path)
    selectors = [ file_input['selector'].presence, 'input[type="file"]' ].compact
    fallback_idx = file_input['form_index']&.to_i

    @page.evaluate(<<~JS)
      (function() {
        var binary = atob(#{cv_data.to_json});
        var bytes  = new Uint8Array(binary.length);
        for (var i = 0; i < binary.length; i++) { bytes[i] = binary.charCodeAt(i); }
        var file = new File([bytes], #{filename.to_json}, { type: 'application/pdf' });
        var dt   = new DataTransfer();
        dt.items.add(file);

        var sels = #{selectors.to_json};
        for (var s = 0; s < sels.length; s++) {
          var el = document.querySelector(sels[s]);
          if (el) {
            el.files = dt.files;
            el.dispatchEvent(new Event('change', { bubbles: true }));
            el.dispatchEvent(new Event('input',  { bubbles: true }));
            return true;
          }
        }

        var idx = #{fallback_idx.nil? ? 'null' : fallback_idx};
        if (idx !== null) {
          var all = document.querySelectorAll(
            'form input:not([type="submit"]):not([type="button"]):not([type="image"]):not([type="reset"]), ' +
            'form textarea, form select'
          );
          var el = all[idx];
          if (el) {
            el.files = dt.files;
            el.dispatchEvent(new Event('change', { bubbles: true }));
            el.dispatchEvent(new Event('input',  { bubbles: true }));
            return true;
          }
        }

        return false;
      })()
    JS
  rescue StandardError => e
    Rails.logger.error "ApplyMate::Client::Browser CV attach failed: #{e.message}"
  end

  # Best-effort reCAPTCHA v3 token refresh. Finds the first [data-sitekey] element,
  # calls grecaptcha.execute to obtain a fresh token, then writes it into every
  # g-recaptcha-response input. No-ops silently when reCAPTCHA is absent.
  def attempt_recaptcha_refresh
    @page.evaluate(<<~JS)
      (function() {
        if (typeof grecaptcha === 'undefined') return;
        var el = document.querySelector('[data-sitekey]');
        if (!el) return;
        var key    = el.getAttribute('data-sitekey');
        var action = el.getAttribute('data-action') || 'submit';
        grecaptcha.ready(function() {
          grecaptcha.execute(key, { action: action }).then(function(token) {
            document.querySelectorAll('[name="g-recaptcha-response"]').forEach(function(i) {
              i.value = token;
            });
          });
        });
      })()
    JS
    wait_for_idle(timeout: 5)
  rescue StandardError
    # non-fatal — submit will proceed without a refreshed token
  end

  # Clicks the first visible element matching selector on the CURRENT page and
  # returns its deterministic unique CSS path (nil if nothing matched). The path
  # is stored for replaying the click after a lost session.
  def click_with_unique_path(selector)
    click_first_visible_with_unique_path(selector)
  end

  def wait_for_idle(timeout: 10)
    @page.network.wait_for_idle(timeout: timeout)
  rescue Ferrum::TimeoutError, Ferrum::PendingConnectionsError
    # ignore pending third-party requests
  end

  def quit
    store_cookies
    @browser.quit
  rescue StandardError => e
    Rails.logger.warn("Browser: quit failed: #{e.message}")
  ensure
    # Released only after Chrome exits: the lock is what stops a second Chrome
    # from booting on the same profile directory.
    @profile&.release
    @profile = nil
  end

  private

  # A returning visitor is one that still holds the site's cookies — including
  # the cf_clearance a solved Cloudflare challenge grants, which is what keeps
  # the next visit from being challenged all over again.
  def restore_cookies
    return if @profile.nil? || !File.exist?(@profile.cookies_file)

    @browser.cookies.load(@profile.cookies_file)
  rescue StandardError => e
    Rails.logger.warn("Browser: could not restore cookies: #{e.message}")
  end

  def store_cookies
    return if @profile.nil?

    @browser.cookies.store(@profile.cookies_file)
  rescue StandardError => e
    Rails.logger.warn("Browser: could not store cookies: #{e.message}")
  end

  def profile_option
    return {} if @profile.nil?

    # STRING key on purpose: Ferrum seeds its own temporary "user-data-dir" and
    # merges browser_options over it, so a symbol key does not replace it — both
    # flags reach Chrome, Chrome honours the first, and the profile silently ends
    # up in the temp directory Ferrum deletes on quit.
    { 'user-data-dir' => @profile.path }
  end

  # Ferrum otherwise runs whatever Chromium it finds. Real Chrome differs from
  # Chromium in ways bot checks read (build strings, codecs, WebGL renderer), so
  # prefer it when the host has it — and fall back silently where it does not,
  # such as the staging container, which ships Chromium only.
  def browser_path_option
    path = self.class.chrome_path
    path ? { browser_path: path } : {}
  end

  def proxy_option(proxy)
    return {} if proxy.blank?

    uri  = URI.parse(proxy.to_s)
    type = uri.scheme.to_s.start_with?('socks') ? 'socks5' : 'http'
    { proxy: { host: uri.host, port: uri.port.to_s, type: type } }
  end

  # Navigates to url and, while Cloudflare keeps serving its "Just a moment…"
  # interstitial, waits for the JS challenge to auto-solve — re-checking the body
  # up to CHALLENGE_POLLS times. We do NOT reload: a reload restarts the challenge
  # and interrupts a solve that was about to complete. Returns the final rendered
  # body (still a challenge page if it never clears within the budget).
  def load_past_cloudflare(page, url)
    goto(page, url)
    nudge(page)
    body  = body_of(page)
    polls = 0
    while cloudflare_challenge?(body) && polls < CHALLENGE_POLLS
      polls += 1
      sleep CHALLENGE_WAIT
      nudge(page)
      body = body_of(page)
    end
    body
  end

  # A challenge page watches for signs of a person: a cursor that never moves
  # while it solves is itself a signal. Cheap, best-effort, never fatal — the
  # page is being read for its body, not driven.
  def nudge(page)
    page.mouse.move(x: rand(80..900), y: rand(80..600))
  rescue StandardError
    nil
  end

  def goto(page, url)
    page.goto(url)
  rescue Ferrum::PendingConnectionsError
    # ignore pending third-party requests (trackers, CF beacons)
  ensure
    page.network.wait_for_idle(timeout: 10) rescue nil
  end

  def cloudflare_challenge?(body)
    body.present? && Response::CLOUDFLARE_MARKERS.any? { |marker| body.include?(marker) }
  end

  def body_of(page)
    page.body
  rescue StandardError
    ''
  end

  def new_page
    page = @browser.create_page
    page.command('Page.addScriptToEvaluateOnNewDocument', source: STEALTH_SCRIPT)
    page
  end

  # Like click but also returns the unique CSS path of the clicked element (or nil).
  # Used internally by click_and_fetch to produce a stable selector for reuse.
  def click_first_visible_with_unique_path(selector)
    @page.evaluate(<<~JS)
      (function() {
        function uniquePath(el) {
          if (el.id) return '#' + CSS.escape(el.id);
          var parts = [];
          var node = el;
          while (node && node.parentElement) {
            var tag = node.tagName.toLowerCase();
            var par  = node.parentElement;
            if (par.id) {
              var same = Array.from(par.children).filter(function(c){ return c.tagName === node.tagName; });
              var idx  = same.indexOf(node) + 1;
              parts.unshift(same.length > 1 ? tag + ':nth-of-type(' + idx + ')' : tag);
              parts.unshift('#' + CSS.escape(par.id));
              return parts.join(' > ');
            }
            var siblings = Array.from(par.children).filter(function(c){ return c.tagName === node.tagName; });
            parts.unshift(siblings.length > 1 ? tag + ':nth-of-type(' + (siblings.indexOf(node) + 1) + ')' : tag);
            if (par === document.body) break;
            node = par;
          }
          return parts.join(' > ');
        }

        var els = document.querySelectorAll(#{selector.to_json});
        for (var i = 0; i < els.length; i++) {
          var el = els[i], node = el, visible = true;
          while (node && node !== document.documentElement) {
            var cs = window.getComputedStyle(node);
            if (cs.display === 'none' || cs.visibility === 'hidden') { visible = false; break; }
            node = node.parentElement;
          }
          if (visible) {
            el.scrollIntoView({ behavior: 'instant', block: 'center' });
            el.click();
            return uniquePath(el);
          }
        }
        return null;
      })()
    JS
  end
end
