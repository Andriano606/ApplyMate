# frozen_string_literal: true

# Builds a self-contained bookmarklet that fills the employer's form in the
# user's OWN browser.
#
# Why a bookmarklet and not a tab we drive ourselves: a page on another origin
# cannot be scripted from ours (same-origin policy), and employer forms forbid
# embedding (Ashby answers with X-Frame-Options: DENY), so an iframe is out too.
# A bookmarklet runs inside the target page, which is the only place allowed to
# touch it — and because it runs in the person's normal browser, nothing looks
# automated, which is what gets an otherwise perfect submission flagged.
#
# Everything travels inside the link: the page's CSP (default-src 'none') blocks
# both loading a script from us and calling back to us.
module Apply::Bookmarklet
  SKIP_TYPES = %w[hidden submit button file].freeze

  # Text is inserted with execCommand so the browser raises a genuine input
  # event — forms that keep their own state ignore a value merely assigned.
  SCRIPT = <<~JS
    (function(){
      var A = __ANSWERS__;
      function norm(s){ return (s||'').replace(/\\s+/g,' ').trim().toLowerCase(); }
      function accName(el){
        if (el.getAttribute('aria-label')) return el.getAttribute('aria-label');
        if (el.labels && el.labels.length) return el.labels[0].textContent;
        var n = el.parentElement;
        for (var i=0; i<4 && n; i++) {
          var l = n.querySelector('label, legend');
          if (l) return l.textContent;
          n = n.parentElement;
        }
        return el.placeholder || '';
      }
      function find(a){
        if (a.name) { var byName = document.querySelector('[name="' + a.name.replace(/"/g,'\\\\"') + '"]'); if (byName) return byName; }
        var all = Array.prototype.slice.call(document.querySelectorAll('input:not([type=hidden]), textarea, select, [role=combobox]'));
        return all.filter(function(el){ return norm(accName(el)) === norm(a.question); })[0] ||
               all.filter(function(el){ return norm(accName(el)).indexOf(norm(a.question)) === 0; })[0] || null;
      }
      function type(el, value, keepFocus){
        el.focus();
        el.select && el.select();
        if (!document.execCommand('insertText', false, value)) {
          var d = Object.getOwnPropertyDescriptor(el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype, 'value');
          d && d.set ? d.set.call(el, value) : (el.value = value);
          el.dispatchEvent(new Event('input', {bubbles:true}));
          el.dispatchEvent(new Event('change', {bubbles:true}));
        }
        if (!keepFocus) el.blur();
      }
      function pickOption(text){
        var opts = Array.prototype.slice.call(document.querySelectorAll('[role=option]'));
        var hit = opts.filter(function(o){ return norm(o.textContent) === norm(text); })[0] ||
                  opts.filter(function(o){ return norm(o.textContent).indexOf(norm(text)) !== -1; })[0];
        if (hit) { hit.click(); return true; }
        return false;
      }
      // A choice question cannot be found by field name: ATS forms regenerate
      // the group's name on every load, and a single option is labelled with its
      // own text, never with the question. Locate the smallest block that states
      // the question, then pick the option inside it.
      function questionBlock(question){
        var needle = norm(question).slice(0, 40);
        if (!needle) return null;
        var nodes = Array.prototype.slice.call(document.querySelectorAll('fieldset, div, section'));
        var hits = nodes.filter(function(n){ return norm(n.textContent).indexOf(needle) !== -1; });
        return hits.length ? hits[hits.length - 1] : null;   // deepest match
      }
      function clickInBlock(question, value, el){
        var block = questionBlock(question) || (el ? el.parentElement : null);
        if (!block) return false;
        var radios = Array.prototype.slice.call(block.querySelectorAll('input[type=radio], input[type=checkbox]'));
        for (var i = 0; i < radios.length; i++) {
          if (norm(accName(radios[i])) === norm(value)) { radios[i].click(); return true; }
        }
        var cand = Array.prototype.slice.call(block.querySelectorAll('button, [role=button], [role=radio], label, div'));
        var hit = cand.filter(function(c){ return norm(c.textContent) === norm(value); })[0];
        if (hit) { hit.click(); return true; }
        return false;
      }

      var done = 0, missed = [], combos = [];
      A.forEach(function(a){
        var choice = (a.type === 'radio' || a.type === 'button_group');
        var el = find(a);
        if (!el && !choice) { missed.push(a.question); return; }
        if (a.type === 'checkbox') {
          if (!!el.checked !== !!a.checked) el.click();
          done++;
        } else if (a.type === 'combobox') {
          combos.push({ el: el, a: a });   // handled last: the list needs time
        } else if (a.type === 'radio' || a.type === 'button_group') {
          clickInBlock(a.question, a.value, el) ? done++ : missed.push(a.question);
        } else {
          type(el, a.value);
          done++;
        }
      });
      // An autocomplete only counts a CHOSEN option, and its dropdown needs a
      // moment to filter — so these run one at a time, falling back to "Other"
      // when the answer is not on the list (the form pairs it with a free-text
      // field we have already filled).
      function nextCombo(i){
        if (i >= combos.length) {
          alert('ApplyMate: заповнено ' + done + ' полів' + (missed.length ? ', не знайдено: ' + missed.join(', ') : '') + '.\\nРезюме прикріпіть вручну, тоді перевірте і надішліть.');
          return;
        }
        var c = combos[i];
        type(c.el, c.a.value, true);
        setTimeout(function(){
          if (pickOption(c.a.value)) { done++; nextCombo(i + 1); return; }
          type(c.el, 'Other', true);
          setTimeout(function(){
            if (pickOption('Other')) { done++; } else { type(c.el, '', true); missed.push(c.a.question); }
            nextCombo(i + 1);
          }, 700);
        }, 700);
      }
      nextCombo(0);
    })();
  JS

  def self.for(apply)
    answers = answers_for(apply)
    return nil if answers.empty?

    "javascript:#{ERB::Util.url_encode(SCRIPT.gsub('__ANSWERS__', answers.to_json))}"
  end

  def self.answers_for(apply)
    Array(apply.filled_inputs).filter_map do |field|
      field = field.to_h.stringify_keys
      next if SKIP_TYPES.include?(field['type'])

      value = field['value'].to_s.strip
      next if value.empty?

      {
        name:     field['name'],
        question: field['accessible_name'].presence || field['label'].presence || field['name'],
        type:     field['type'],
        value:    option_value(field, value),
        checked:  Apply::FormFiller::CHECKED_VALUES.include?(value.downcase)
      }
    end
  end

  # The stored value can be a raw "label=value" pair; a person's browser needs
  # the label, since that is what the option shows.
  def self.option_value(field, value)
    return value unless %w[radio button_group select combobox].include?(field['type'])

    wanted = value.downcase.split('=').map(&:strip)
    label  = Array(field['options']).map { |o| o.to_h.stringify_keys }
                                    .find { |o| wanted.include?(o['label'].to_s.downcase.strip) }
    label ? label['label'] : value.split('=').first.to_s
  end
end
