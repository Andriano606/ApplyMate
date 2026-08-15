# frozen_string_literal: true

# Types the resolved answers into a live page. Shared by the automatic loop
# (External::Generic) and assisted mode, so a form a person finishes by hand is
# filled exactly the way the robot would have filled it.
#
# Never submits — pressing submit belongs to the caller.
class Apply::FormFiller
  # Values that mean "tick this box" once a consent question has been answered.
  CHECKED_VALUES = %w[on true yes 1 y так так. згоден agree accept checked].freeze

  # Ashby offers a second file input ("Autofill from resume") that re-parses the
  # CV and overwrites everything already typed — never upload there.
  AUTOFILL_LABEL = /autofill|auto-fill|parse|заповнити з резюме/i
  RESUME_LABEL   = /resume|cv|résumé|резюме/i

  def initialize(browser:, cv_path: nil)
    @browser = browser
    @cv_path = cv_path
  end

  # inputs: filled_inputs already carrying handles valid for THIS page.
  def fill(inputs)
    inputs.each do |input|
      input = input.to_h.stringify_keys
      next if input['type'] == 'file'
      next if input['value'].blank? && input['type'] != 'checkbox'

      fill_input(input)
    end

    attach_cv(inputs.map { |i| i.to_h.stringify_keys })
  end

  # Re-maps stored answers onto a freshly snapshotted page: fingerprint first
  # (survives renames and reordering), then name, label and position.
  def self.remap(stored, fresh)
    stored = Array(stored).map { |i| i.to_h.stringify_keys }
    fresh  = Array(fresh).map { |f| f.to_h.stringify_keys }

    fresh.filter_map do |field|
      answer = stored.find { |s| s['fingerprint'].present? && s['fingerprint'] == field['fingerprint'] } ||
               stored.find { |s| s['name'].present? && s['name'] == field['name'] } ||
               stored.find { |s| s['accessible_name'].present? && s['accessible_name'] == field['accessible_name'] } ||
               # Position is the last resort and only when both sides really have
               # one — nil == nil would hand a brand-new field someone else's answer.
               stored.find { |s| !s['form_index'].nil? && s['form_index'] == field['form_index'] }
      next if answer.nil?

      field.merge('value' => answer['value'], 'role' => answer['role'])
    end
  end

  private

  def fill_input(input)
    type    = input['type'].to_s
    options = Array(input['options'])

    return choose_option(input) if type == 'button_group' || type == 'radio'
    return toggle_checkbox(input) if type == 'checkbox' && options.size <= 1
    return choose_option(input) if type == 'checkbox'

    if input['handle'].present?
      @browser.fill_by_handle(input['handle'], input['value'].to_s, input['tag'].to_s)
    else
      @browser.fill_field(input['selector'], input['value'].to_s, input['tag'].to_s, form_index: input['form_index'])
    end
  end

  # A lone checkbox (consents, opt-outs) is driven by its checked state.
  def toggle_checkbox(input)
    handle = input['handle'].presence || Array(input['options']).first.to_h.stringify_keys['handle']
    return if handle.blank?

    @browser.set_checkbox_by_handle(handle, CHECKED_VALUES.include?(input['value'].to_s.strip.downcase))
  end

  # Button-built choice questions (Ashby's Yes/No) and radio groups are answered
  # by clicking the matching option, not by writing a value anywhere.
  def choose_option(input)
    options = Array(input['options']).map { |o| o.to_h.stringify_keys }
    # Options are shown to the AI as "label=value", and it sometimes answers with
    # the whole pair ("Man=on") — accept either half rather than losing the answer.
    wanted = wanted_variants(input['value'])
    option = options.find { |o| wanted.include?(o['label'].to_s.strip.downcase) } ||
             options.find { |o| wanted.include?(o['value'].to_s.strip.downcase) } ||
             options.find { |o| wanted.any? { |w| o['label'].to_s.downcase.include?(w) } }

    if option.nil? || option['handle'].blank?
      Rails.logger.info("FormFiller: no option matching #{input['value'].inspect} for #{input['name'].inspect}")
      return
    end

    @browser.click_by_handle(option['handle'])
  end

  def wanted_variants(value)
    raw = value.to_s.strip.downcase
    return [] if raw.blank?

    [ raw, raw.split('=').first, raw.split('=').last ].compact.map(&:strip).reject(&:blank?).uniq
  end

  def attach_cv(inputs)
    return if @cv_path.blank?

    file_inputs = inputs.select { |i| i['type'] == 'file' }
    return if file_inputs.empty?

    named      = ->(i) { "#{i['accessible_name']} #{i['label']} #{i['name']}" }
    candidates = file_inputs.reject { |i| named.call(i).match?(AUTOFILL_LABEL) }
    file_input = candidates.find { |i| named.call(i).match?(RESUME_LABEL) } ||
                 candidates.last || file_inputs.last
    return if file_input.nil?

    if file_input['handle'].present?
      @browser.attach_file_by_handle(file_input['handle'], @cv_path)
    else
      @browser.attach_file(file_input, @cv_path)
    end
  end
end
