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
#              aria-haspopup (a typeahead, no select chrome) is an `autocomplete`; a text input whose placeholder is a
#              date mask (Widget::DateInput.masked?, "dd.mm.yyyy") is a `date`
#   widget     the key of Apply::Widget::Registry.find (nil when no driver handles the kind; filling such a field halts
#              no_widget_driver); a chooser is always `dropzone` (its kind alone would pick FileInput)
#   target     the control's Target; a group's carries the field root as `root` (OptionGroup reads its options there)
#   default    the value already in a prefilled text-like control (read_value probe), never sent to the AI
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

  # The ONE "is this snapshot element a fillable control" rule (inventory units, AssessFormLikeness, the Navigator's
  # FIELDS line and its implicit-submit guard): inputs except buttons, textarea, select, grouped elements and
  # textbox / combobox / radio / checkbox / switch roles that are not a <button>, and `chooser` upload buttons; never
  # search-like or disabled ones.
  def self.control?(element)
    return false if element['search_like'] || element['disabled']
    return true if element['group'].present? || element['chooser']
    return BUTTON_TYPES.exclude?(element['type']) if element['tag'] == 'input'
    return true if %w[textarea select].include?(element['tag'])

    CONTROL_ROLES.include?(element['role']) && element['tag'] != 'button'
  end

  def perform!(ctx:, snapshot:, **)
    skip_authorize
    @ctx = ctx
    @schema = Array(ctx.schema).index_by(&:id)
    elements = Apply::Operation::Engine::FormElements.call(ctx:, snapshot:).model
    ordinals = Hash.new(0)
    fields = units(elements).map do |members|
      field = build(members)
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
    groups = elements.select { |element| self.class.control?(element) }.group_by { |element| unit_key(element) }
    groups.values
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
    label = schema&.label || dom_label(first, kind)
    options = schema&.options.presence || dom_options(first, members, dom_kind)
    target = target_of(first, kind)
    field = Apply::Field.new(
      id:, kind:, label:, description: schema&.description, placeholder: first.dig('attrs', 'placeholder').presence,
      required: schema ? schema.required == true : members.any? { |member| member['required'] },
      multiple: schema&.multiple == true || first.dig('attrs', 'multiple') == true || Apply::Field::MULTI_KINDS.include?(kind),
      max_length: first.dig('attrs', 'maxlength').to_i.positive? ? first.dig('attrs', 'maxlength').to_i : nil,
      accept: first.dig('attrs', 'accept').presence, autocomplete: first.dig('attrs', 'autocomplete').presence, options:,
      semantic: first['password'] ? 'password' : nil,
      widget: nil, target:, signature: Apply::Field.signature_for(label:, kind:, option_labels: option_labels(options)),
      ordinal: 0, default_value: default_value(first, kind, target), condition: schema&.condition,
      source: schema ? 'schema_api' : 'snapshot', page: nil
    )
    field.with(widget: first['chooser'] ? Apply::Widget::Dropzone.key : Apply::Widget::Registry.find(field)&.key)
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
    kind = INPUT_KINDS.fetch(first['type'].to_s, 'text')
    kind == 'text' && Apply::Widget::DateInput.masked?(first.dig('attrs', 'placeholder')) ? 'date' : kind
  end

  def autocomplete?(first)
    attrs = first['attrs'] || {}
    !first['readonly'] && AUTOCOMPLETE_LISTS.include?(attrs['aria-autocomplete']) && attrs['aria-haspopup'].blank?
  end

  # A group is named by its question, a control by its own name (a name that only repeats the placeholder is no
  # label).
  def dom_label(first, kind)
    name = first['name'].presence
    name = nil if name == first.dig('attrs', 'placeholder')
    question = first['question'].presence
    GROUP_KINDS.include?(kind) ? question || name : name || question
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
