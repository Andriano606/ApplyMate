# frozen_string_literal: true

module Apply::Operation::FormExtractor
  def extract_form_data(doc, page_url, cookies, selector: 'form')
    form = doc.at_css(selector)
    raise "No form found on employer page (selector: #{selector})" if form.nil?

    action = resolve_url(form['action'].presence || page_url, page_url)
    method = (form['method'] || 'post').downcase

    submit_btn      = form.at_css('button[type="submit"], input[type="submit"]')
    submit_selector = submit_btn ? derive_submit_selector(submit_btn) : 'button[type="submit"]'
    submit_text     = submit_btn&.text&.strip.presence

    inputs    = []
    form_idx  = 0
    form.css('input, textarea, select').each do |el|
      tag  = el.name
      type = tag == 'input' ? (el['type'] || 'text').downcase : tag
      next if %w[submit button image reset].include?(type)

      # Vue/React SPAs often omit the name attribute — fall back to id then
      # placeholder so AI-driven filling still receives all visible fields.
      name = el['name'].to_s.strip
      name = el['id'].to_s.strip          if name.blank?
      name = el['placeholder'].to_s.strip if name.blank?
      next if name.blank?

      accessible_name = accessible_name_for(doc, el)

      entry = {
        'name'            => name,
        'selector'        => derive_selector(el),
        'form_index'      => form_idx,
        'position'        => form_idx,
        'tag'             => tag,
        'type'            => type,
        'accessible_name' => accessible_name,
        'label'           => accessible_name,
        'placeholder'     => el['placeholder'].to_s,
        'required'        => required_field?(el, accessible_name),
        'autocomplete'    => el['autocomplete'].to_s,
        'fieldset'        => fieldset_legend_for(el),
        'role'            => nil,
        'value'           => tag == 'textarea' ? el.text.strip : el['value'].to_s
      }

      if tag == 'select'
        entry['options'] = el.css('option').map { |o| { 'label' => o.text.strip, 'value' => o['value'].to_s } }
        entry['value']   = el.at_css('option[selected]')&.[]('value').to_s
      end

      if type == 'radio' || type == 'checkbox'
        entry['options'] ||= []
        entry['options'] << { 'label' => (el['aria-label'] || el['id'] || entry['value']).to_s, 'value' => entry['value'] }
      end

      entry['fingerprint'] = Apply::FieldFingerprint.call(entry)

      form_idx += 1
      inputs << entry
    end

    {
      'action'          => action,
      'http_method'     => method,
      'submit_selector' => submit_selector,
      'submit_text'     => submit_text,
      'inputs'          => merge_radio_groups(inputs),
      'cookies'         => cookies
    }
  end

  private

  def derive_selector(el)
    id = el['id'].to_s.strip
    if id.present?
      # IDs with brackets/dots (e.g. Rails array params like "form[field][]") are valid HTML
      # but break querySelectorAll when prefixed with #. Use the attribute form instead.
      return id.match?(/\A[\w-]+\z/) ? "##{id}" : "[id=\"#{id}\"]"
    end

    name = el['name'].to_s.strip
    return "[name=\"#{name}\"]" if name.present?

    placeholder = el['placeholder'].to_s.strip
    return "[placeholder=\"#{placeholder}\"]" if placeholder.present?

    el.name
  end

  # Builds a submit-button selector that survives SPA re-renders.
  # Prefers a stable ID, then falls back to tag[type] + filtered classes.
  # Filtered classes exclude: mixed-case (CSS-in-JS hashes), 3+ consecutive
  # digits (framework-generated suffixes), and non-letter-starting tokens.
  def derive_submit_selector(el)
    id = el['id'].to_s.strip
    return "##{id}" if id.present? && stable_id?(id)

    type_attr = el['type'].to_s.strip
    base      = type_attr.present? ? "#{el.name}[type=\"#{type_attr}\"]" : el.name
    stable    = (el['class'] || '').split.select { |c| stable_class?(c) }
    stable.empty? ? base : "#{base}.#{stable.join('.')}"
  end

  def stable_id?(id)
    id.match?(/\A[\w-]+\z/) &&   # only plain word/hyphen chars are safe as a CSS #id selector
      id == id.downcase &&
      !id.match?(/[0-9a-f]{5,}/) &&
      !id.match?(/\d{3,}/)
  end

  def stable_class?(cls)
    cls.present? &&
      cls == cls.downcase &&    # mixed/uppercase → CSS-in-JS hash
      !cls.match?(/\d{3,}/) &&  # 3+ consecutive digits → generated suffix
      cls.match?(/\A[a-z]/) &&  # must start with a letter
      !cls.include?(':')         # colons (Tailwind variant prefixes) are invalid in CSS selectors
  end

  # Simplified accname, mirroring Browser#snapshot_fields:
  # aria-label > label[for] / wrapping label > placeholder.
  def accessible_name_for(doc, el)
    aria = el['aria-label'].to_s.strip
    return aria if aria.present?

    label = find_label(doc, el)
    return label if label.present?

    el['placeholder'].to_s.strip
  end

  def required_field?(el, accessible_name)
    !el['required'].nil? || el['aria-required'] == 'true' || accessible_name.include?('*')
  end

  def fieldset_legend_for(el)
    parent = el.parent
    while parent && parent.name != 'body'
      return parent.at_css('legend')&.text.to_s.strip if parent.name == 'fieldset'
      parent = parent.parent
    end

    ''
  end

  def find_label(doc, el)
    id = el['id'].to_s
    if id.present?
      label_node = doc.at_css("label[for='#{id}']")
      return label_node.text.strip if label_node
    end

    # Walk up looking for a wrapping <label> only — never grab a label that
    # belongs to a sibling field, which `at_css('label')` on an ancestor would do.
    parent = el.parent
    while parent && parent.name != 'form' && parent.name != 'body'
      return parent.text.strip if parent.name == 'label'
      parent = parent.parent
    end

    ''
  end

  def merge_radio_groups(inputs)
    seen   = {}
    result = []

    inputs.each do |entry|
      next result << entry unless %w[radio checkbox].include?(entry['type'])

      name = entry['name']
      if seen[name]
        seen[name]['options'] = (seen[name]['options'] || []) + (entry['options'] || [])
      else
        seen[name] = entry
        result << entry
      end
    end

    result
  end

  def extract_cookies(headers)
    raw = headers['set-cookie']
    cookies = raw.is_a?(Array) ? raw : raw.to_s.split(/,\s*(?=[a-zA-Z0-9_\-]+=)/)
    cookies.map { |c| c.split(';').first.to_s.strip }.reject(&:blank?).join('; ')
  end

  def resolve_url(href, base_url)
    return base_url if href.blank?

    URI.join(base_url, href).to_s
  rescue URI::InvalidURIError
    href
  end
end
