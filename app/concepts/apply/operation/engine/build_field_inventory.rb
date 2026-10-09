# frozen_string_literal: true

# The form's fields from one snapshot (design §7.1, FieldInventory.build): one Apply::Field per control or control
# group of the form (Engine::FormElements: the form root's frame and region, minus platform.excluded_regions), in DOM
# order, search-like and disabled controls left out.
#
#   grouping   radio groups and answer-button groups (the probe's group_key), checkboxes sharing one field root (2+
#              -> checkbox_group); every other control is its own field
#   identity   platform.field_key(RawField) (Ashby: "ashby:<data-field-path>"), else "f_<signature>_<ordinal>";
#              signature = Apply::Field.signature_for(label, kind, option labels), ordinal = position among equal
#              signatures. Two fields with one id -> Halt(:unexpected_error, detail: 'field id collision')
#   schema     a schema field (ctx.schema) with the same id is merged: the schema wins for kind, label, description,
#              required and options (source 'schema_api'); the DOM wins for the target and therefore the widget, and
#              decides between the single-choice kinds (SINGLE_CHOICE: an Ashby ValueSelect / Boolean is a combobox,
#              radios or Yes/No buttons depending on how it rendered)
#   kind       the schema's, else the DOM's: a `chooser` button (snapshot.js: an upload button with no file input in
#              its field root) is a `file`; a role=combobox text input with aria-autocomplete list/both and no
#              aria-haspopup (a typeahead, no select chrome) is an `autocomplete`, and so is an ARIA-less typeahead
#              (snapshot.js `typeahead`: a text input beside a suggestion container, Lever's location input); a text
#              input whose placeholder is a date mask (Widget::DateInput.masked?, "dd.mm.yyyy") is a `date`; a custom
#              select (snapshot.js combobox group: a readonly input over a list, an aria-haspopup=listbox trigger) is a
#              `combobox`
#   widget     the key of Apply::Widget::Registry.find (nil when no driver handles the kind; filling such a field halts
#              no_widget_driver); a chooser is always `dropzone` (its kind alone would pick FileInput), an ARIA-less
#              typeahead `typeahead` (Widget::Typeahead: keeps the typed text when no suggestion appears)
#   options    a select's / group's own options; a combobox's are read by opening it (Engine::ReadComboboxOptions, the
#              first MAX_PROBED_COMBOBOXES comboboxes of the inventory still 'dynamic', each time-clamped); 'dynamic'
#              when nothing opened, for every autocomplete (its options depend on what is typed) and past the cap.
#              The signature is taken before (from 'dynamic'), so a probe that fails once never changes a field's id
#   target     the control's Target; a group's carries the field root as `root` (OptionGroup reads its options there)
#   default    the value already in a prefilled text-like control (read_value probe), never sent to the AI
#   signature  keyed by the label, else the placeholder, else the aria-describedby text (`description`), so fields
#              named only by a placeholder differ by more than their ordinal
#   label      a group's question, else the control's own name, else the question, else a non-generic placeholder
#              without its trailing `*` (placeholder_label); a generic name (an upload verb:
#              Answer::Classify.generic_name?) yields to the question. A checkbox keeps its own name (Widget::NativeCheck
#              clicks its label by that text); a generic one ("Acknowledge/Confirm") gets the question as its
#              description, which Answer::Classify then reads
#   description the aria-describedby text, else that generic checkbox's question, else the field root's help text
#              (snapshot.js `help`: Ashby's question-description block beside the label, no aria-describedby)
#   required   the DOM's flag (required / aria-required / a `*` mark), else implied (REQUIRED_LEXICON incl. a `*` / `✱`
#              left in the label / placeholder, CORE_SEMANTICS; `cv` only for a file field whose label names the CV,
#              Answer::Classify.cv_file?), never when OPTIONAL_LEXICON says "optional")
#   helpers    helper? controls (aria-hidden, readonly, a captcha response) and non-rendered ones (visible=false: a
#              display:none twin of a framework widget, a hidden textarea under a rich-text editor) are not controls
#              at all; neither are resume-parse helpers (Answer::Classify.helper_control?: "Autofill from resume")
#   dropped    an optional snapshot field with no label and no description (an empty <label>): nothing to answer
#   left out  `left_out:` (Stage::DiscoverFields from Engine::Navigate's accepted claim): optional controls the
#              Navigator saw inside the form and did not list as its fields
#
# model = [Apply::Field]
class Apply::Operation::Engine::BuildFieldInventory < ApplyMate::Operation::Base
  BUTTON_TYPES = %w[submit button reset image].freeze
  CONTROL_ROLES = %w[textbox combobox radio checkbox switch].freeze
  CHECKBOX_ROLES = %w[checkbox switch].freeze
  INPUT_KINDS = {
    'email' => 'email', 'tel' => 'tel', 'url' => 'url', 'number' => 'number', 'date' => 'date',
    'datetime-local' => 'date', 'month' => 'date', 'week' => 'date', 'file' => 'file', 'range' => 'range'
  }.freeze
  GROUP_KINDS = %w[radio_group option_group checkbox_group].freeze
  # Single-choice kinds: the schema says "one of these options", the DOM says how they are picked.
  SINGLE_CHOICE = %w[select combobox autocomplete radio_group option_group].freeze
  DEFAULT_VALUE_KINDS = %w[text email tel url number textarea date select].freeze
  # aria-autocomplete values of a typeahead (Widget::Autocomplete) rather than a select-like combobox.
  AUTOCOMPLETE_LISTS = %w[list both].freeze
  # Required-ness a JS-only validator (Vuetify rules, Hurma) never puts in the DOM: a required word or a `*` / `✱` mark
  # in the label / placeholder (snapshot.js reads the marks it strips), or a fact every application form asks for
  # (CORE_SEMANTICS, Answer::Classify). An "optional" word wins over both ("Phone (optional)", "необов'язково"). Only
  # ever turns a DOM-optional field required, never the reverse; a schema API's required flag is final.
  REQUIRED_LEXICON = /(?<!не)обов.язков|(?<!not )(?<!non-)\brequired\b|(?<!не)обязательн|(?:\A|\s)[*✱]|[*✱]\s*\z/i
  OPTIONAL_LEXICON = /\boptional\b|\bnot required\b|необов.язков|необязательн|за бажанням|по желанию/i
  CORE_SEMANTICS = %w[full_name first_name last_name email phone cv].freeze
  # A trailing required mark on a placeholder used as the label.
  PLACEHOLDER_MARK = /[\s*✱]+\z/
  # Comboboxes opened per inventory to read their options (Engine::ReadComboboxOptions, ~2-3 s each at worst).
  MAX_PROBED_COMBOBOXES = 6

  # The ONE "is this snapshot element a fillable control" rule (inventory units, AssessFormLikeness, the Navigator's
  # FIELDS line and its implicit-submit guard): inputs except buttons, textarea, select, grouped elements and
  # textbox / combobox / radio / checkbox / switch roles that are not a <button>, and `chooser` upload buttons; never
  # search-like, disabled, helper (helper?) or non-rendered ones. `visible` is snapshot.js's rendered flag, which
  # already counts a styled radio / checkbox / combobox through its label or field root; a file input is hidden by
  # design and filled through setInputFiles, so it never needs one.
  def self.control?(element)
    return false if element['search_like'] || element['disabled'] || helper?(element)
    return false unless element['visible'] || element['type'] == 'file'
    return true if element['group'].present? || element['chooser']
    return BUTTON_TYPES.exclude?(element['type']) if element['tag'] == 'input'
    return true if %w[textarea select].include?(element['tag'])

    CONTROL_ROLES.include?(element['role']) && element['tag'] != 'button'
  end

  # A control nobody fills: a captcha's response textarea (snapshot.js captcha_artifact: g-recaptcha-response,
  # h-captcha-response, cf-turnstile-response), a framework helper (Vuetify's auto-grow `<textarea id=...-sizer
  # aria-hidden readonly tabindex=-1>`) inside aria-hidden, or any readonly control (nothing can be typed into it; a
  # readonly input that opens a list is a `combobox` group, filled by clicking). Never a file input, an upload chooser,
  # a radio / option / combobox group member, nor a styled control shown through its visible field root (a transparent
  # checkbox): those are hidden by design and filled through their root.
  def self.helper?(element)
    return true if element['captcha_artifact']
    return false if element['type'] == 'file' || element['chooser'] || element['group'].present?
    return false if element['visible'] && !element['self_visible']

    element['aria_hidden'] || element['readonly']
  end

  # An element's css path in its frame (its first css strategy: snapshot.js's tag:nth-of-type chain): the key that
  # ties one snapshot's element to the same element in another snapshot of the same page state (Engine::Navigate's
  # claimed root and `left_out`).
  def self.dom_key(element)
    Array(element['strategies']).find { |strategy| strategy['css'].present? }&.fetch('css')
  end

  # left_out: dom_keys of controls the Navigator's accepted claim left out (Stage::DiscoverFields, first page only).
  def perform!(ctx:, snapshot:, left_out: Set.new, **)
    skip_authorize
    @ctx = ctx
    @left_out = left_out
    @schema = Array(ctx.schema).index_by(&:id)
    @probed = 0
    elements = Apply::Operation::Engine::FormElements.call(ctx:, snapshot:).model
    ordinals = Hash.new(0)
    fields = units(elements).map { |members| build(members) }.reject { |field| unlabelled_optional?(field) }
    fields = fields.map { |field| with_probed_options(field) }
    fields = fields.map do |field|
      ordinal = ordinals[field.signature]
      ordinals[field.signature] += 1
      field.with(ordinal:, id: field.id || "f_#{field.signature}_#{ordinal}")
    end
    raise Apply::Operation::Engine::Halt.new(:unexpected_error, detail: 'field id collision') if fields.uniq(&:id).size != fields.size

    self.model = fields
  end

  private

  attr_reader :ctx

  # [[element, ...], ...]: one entry per field, DOM order of the first member.
  def units(elements)
    controls = elements.select do |element|
      self.class.control?(element) && !parse_helper?(element) && @left_out.exclude?(self.class.dom_key(element))
    end
    controls.group_by { |element| unit_key(element) }.values
  end

  def parse_helper?(element)
    Apply::Operation::Answer::Classify.helper_control?(element['name'], element['question'], element['described_by'])
  end

  # Nothing tells what to answer and nothing requires an answer (an empty <label> before a bare "Type here..." input).
  def unlabelled_optional?(field)
    return false if field.source != 'snapshot' || field.required || field.label.present? || field.description.present?

    field.placeholder.blank? || Apply::Operation::Answer::Classify.generic_name?(field.placeholder)
  end

  def unit_key(element)
    return element['group_key'] if element['group_key'].present?
    return "checkbox:#{element['root_strategies'].to_json}" if checkbox?(element) && element['root_strategies'].present?

    "element:#{element['ref']}"
  end

  def checkbox?(element)
    element['type'] == 'checkbox' || CHECKBOX_ROLES.include?(element['role'])
  end

  def build(members)
    first = members.first
    raw = Apply::Platform::Base::RawField.new(element: first, default_key: nil)
    id = ctx.platform&.field_key(raw)
    schema = id && @schema[id]
    dom_kind = dom_kind(first, members)
    kind = merged_kind(schema&.kind, dom_kind)
    placeholder = first.dig('attrs', 'placeholder').presence
    label = schema&.label || dom_label(first, kind) || placeholder_label(placeholder)
    options = schema&.options.presence || dom_options(first, members, dom_kind)
    target = target_of(first, kind)
    description = schema&.description || first['described_by'].presence || generic_question(first, label) || first['help'].presence
    field = Apply::Field.new(
      id:, kind:, label:, description:, placeholder:,
      required: schema ? schema.required == true : members.any? { |member| member['required'] },
      multiple: schema&.multiple == true || first.dig('attrs', 'multiple') == true || Apply::Field::MULTI_KINDS.include?(kind),
      max_length: first.dig('attrs', 'maxlength').to_i.positive? ? first.dig('attrs', 'maxlength').to_i : nil,
      accept: first.dig('attrs', 'accept').presence, autocomplete: first.dig('attrs', 'autocomplete').presence,
      prefix: first['prefix'].presence, options:,
      semantic: first['password'] ? 'password' : nil,
      widget: nil, target:,
      signature: Apply::Field.signature_for(label: label.presence || placeholder || description, kind:,
                                            option_labels: option_labels(options)),
      ordinal: 0, default_value: default_value(first, kind, target), condition: schema&.condition,
      source: schema ? 'schema_api' : 'snapshot', page: nil
    )
    field = field.with(required: true) if schema.nil? && !field.required && implied_required?(field)
    field.with(widget: widget_key(first, field))
  end

  def widget_key(first, field)
    return Apply::Widget::Dropzone.key if first['chooser']
    return Apply::Widget::Typeahead.key if first['typeahead'] && field.kind == 'autocomplete'

    Apply::Widget::Registry.find(field)&.key
  end

  def with_probed_options(field)
    return field unless field.kind == 'combobox' && field.options == 'dynamic' && field.target
    return field if @probed >= MAX_PROBED_COMBOBOXES

    @probed += 1
    options = Apply::Operation::Engine::ReadComboboxOptions.call(ctx:, target: field.target).model
    options ? field.with(options:) : field
  end

  def implied_required?(field)
    texts = [ field.label, field.placeholder ].map(&:to_s)
    return false if texts.any? { |text| text.match?(OPTIONAL_LEXICON) }
    return true if texts.any? { |text| text.match?(REQUIRED_LEXICON) }

    semantic = Apply::Operation::Answer::Classify.call(field:, platform: ctx.platform).model
    return Apply::Operation::Answer::Classify.cv_file?(field) if semantic == 'cv'

    CORE_SEMANTICS.include?(semantic)
  end

  def merged_kind(schema_kind, dom_kind)
    return dom_kind if schema_kind.nil?
    return dom_kind if SINGLE_CHOICE.include?(schema_kind) && SINGLE_CHOICE.include?(dom_kind)

    schema_kind
  end

  def dom_kind(first, members)
    return 'file' if first['chooser']
    return autocomplete?(first) ? 'autocomplete' : 'combobox' if first['group'] == 'combobox'
    return first['group'] if %w[radio_group option_group].include?(first['group'])
    return members.size > 1 ? 'checkbox_group' : 'checkbox' if checkbox?(first)

    case first['tag']
    when 'select' then first.dig('attrs', 'multiple') ? 'multiselect' : 'select'
    when 'textarea' then 'textarea'
    when 'input' then input_kind(first)
    else 'rich_text'
    end
  end

  def input_kind(first)
    return 'autocomplete' if first['typeahead']

    kind = INPUT_KINDS.fetch(first['type'].to_s, 'text')
    kind == 'text' && Apply::Widget::DateInput.masked?(first.dig('attrs', 'placeholder')) ? 'date' : kind
  end

  def autocomplete?(first)
    attrs = first['attrs'] || {}
    !first['readonly'] && AUTOCOMPLETE_LISTS.include?(attrs['aria-autocomplete']) && attrs['aria-haspopup'].blank?
  end

  # A group is named by its question, a control by its own name (a name that only repeats the placeholder, or only
  # says "Attach" / "Acknowledge/Confirm", is no label).
  def dom_label(first, kind)
    name = first['name'].presence
    name = nil if name == first.dig('attrs', 'placeholder')
    name = nil if kind != 'checkbox' && Apply::Operation::Answer::Classify.generic_name?(name)
    question = first['question'].presence
    GROUP_KINDS.include?(kind) ? question || name : name || question
  end

  # The field root's question for a field whose label says nothing ("Acknowledge/Confirm" under "GDPR").
  # A placeholder-only control ("Ім'я та прізвище *", Vuetify / Hurma) is labelled by its placeholder, without the
  # trailing required mark (snapshot.js already read it into `required`); never by a generic one ("Type here...") nor
  # a date mask ("dd.mm.yyyy"): those say nothing, and the field stays unlabelled (unlabelled_optional?).
  def placeholder_label(placeholder)
    return if Apply::Operation::Answer::Classify.generic_name?(placeholder) || Apply::Widget::DateInput.masked?(placeholder)

    placeholder.to_s.sub(PLACEHOLDER_MARK, '').squish.presence
  end

  def generic_question(first, label)
    question = first['question'].presence
    question if question && question != label && Apply::Operation::Answer::Classify.generic_name?(label)
  end

  def dom_options(first, members, kind)
    case kind
    when 'select', 'multiselect'
      Array(first['options']).reject { |option| option['disabled'] || option['value'].blank? }
                             .map { |option| { 'label' => option['label'], 'value' => option['value'] } }
    when 'radio_group', 'option_group'
      Array(first['options']).map { |option| { 'label' => option['label'], 'value' => option['value'].presence || option['label'] } }
    when 'checkbox_group'
      members.map { |member| { 'label' => member['name'], 'value' => member.dig('attrs', 'value').presence || member['name'] } }
    when 'combobox', 'autocomplete' then 'dynamic'
    end
  end

  def option_labels(options)
    options.pluck('label') if options.is_a?(Array)
  end

  # Groups keep their field root on the target: OptionGroup reads the options there and Locate judges visibility on it.
  def target_of(first, kind)
    target = first['target']
    return target unless GROUP_KINDS.include?(kind)

    target.with(root: first['root_strategies'].presence || target.root)
  end

  def default_value(first, kind, target)
    return unless first['filled'] && DEFAULT_VALUE_KINDS.include?(kind)

    ctx.session.probe(:read_value, target)&.fetch('value', nil).presence
  rescue ApplyMate::Client::Browser::TargetNotFound
    nil
  end
end
