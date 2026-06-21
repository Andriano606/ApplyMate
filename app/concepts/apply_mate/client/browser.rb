# frozen_string_literal: true

class ApplyMate::Client::Browser
  # CHROME_HOST = ENV.fetch('CHROME_HOST', 'chrome-vnc')
  # CHROME_PORT = ENV.fetch('CHROME_PORT', 9222)

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

  # proxy: optional proxy URL string ("http://host:port" / "socks5://host:port").
  # Routes Chrome through it so Cloudflare-protected sites see the proxy IP while a
  # real browser solves the JS challenge that the raw HTTP client cannot.
  def initialize(proxy: nil)
    @browser = Ferrum::Browser.new(
      window_size: [ 1920, 1080 ],
      **proxy_option(proxy),
      browser_options: {
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

  def screenshot
    @page.screenshot(encoding: :binary)
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

  def wait_for_idle(timeout: 10)
    @page.network.wait_for_idle(timeout: timeout)
  rescue Ferrum::TimeoutError, Ferrum::PendingConnectionsError
    # ignore pending third-party requests
  end

  def quit
    @browser.quit
  end

  private

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
    body  = body_of(page)
    polls = 0
    while cloudflare_challenge?(body) && polls < CHALLENGE_POLLS
      polls += 1
      sleep CHALLENGE_WAIT
      body = body_of(page)
    end
    body
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

  def current_url(page)
    page.current_url
  rescue StandardError
    nil
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
