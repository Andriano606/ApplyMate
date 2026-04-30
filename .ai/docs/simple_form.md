# Simple Form

SimpleForm is configured in `config/initializers/simple_form.rb` with Tailwind-based wrappers. All templates are `.html.slim`.

## Golden rule

**Always use the form builder — never write raw `input`, `select`, or `textarea` tags inside a form.** Raw HTML bypasses name-scoping, skips error classes, ignores wrappers, and breaks `turbo-form#update` serialisation.

```slim
/ ✅ correct — name-scoped, error-aware, wrapper applied
= f.input :status, as: :select, collection: Widget::STATUSES
= f.input :exclude_tags, as: :hidden, input_html: { data: { search_tags_target: 'tagsInput' } }

/ ❌ never do this
select name="widget[status]"
  - Widget::STATUSES.each do |s|
    option value=s = s
input type="hidden" name="exclude_tags" data-search-tags-target="tagsInput" value=@exclude_tags.to_s
```

Any extra HTML attributes (Stimulus targets, data values, ARIA attrs) belong in `input_html:`, not on a hand-rolled tag.

## Basic usage in a component

Inside a ViewComponent, call `helpers.simple_form_for` and yield the form object:

```slim
/ new.html.slim
= helpers.simple_form_for @widget, url: helpers.widgets_path, method: :post do |f|
  = render Widget::Component::Form.new(form: f)
  .mt-6.flex.items-center.gap-4
    = f.submit I18n.t('widget.new.submit'), \
        class: 'px-6 py-2 bg-indigo-600 text-white text-sm font-medium rounded-lg hover:bg-indigo-700 transition-colors cursor-pointer'
    = helpers.link_to I18n.t('widget.new.cancel'), helpers.widgets_path, \
        class: 'px-6 py-2 text-sm font-medium text-gray-700 dark:text-gray-300 hover:text-gray-900 dark:hover:text-white transition-colors'
```

```slim
/ edit.html.slim
= helpers.simple_form_for @widget, url: helpers.widget_path(@widget), method: :patch do |f|
  = render Widget::Component::Form.new(form: f)
  .mt-6.flex.items-center.gap-4
    = f.submit I18n.t('widget.edit.submit'), \
        class: 'px-6 py-2 bg-indigo-600 text-white text-sm font-medium rounded-lg hover:bg-indigo-700 transition-colors cursor-pointer'
```

Pass the form object to a shared `Form` component so the same fields are reused by both new and edit:

```slim
/ form.html.slim — receives `form:` as an init param
= form.input :name, label: I18n.t('widget.form.name')
= form.input :description, as: :text, label: I18n.t('widget.form.description'), input_html: { rows: 5 }
```

## `f.input` options

| Option | Purpose | Example |
|--------|---------|---------|
| `label:` | Override label text | `label: I18n.t('widget.form.name')` |
| `as:` | Force input type | `as: :text`, `as: :select`, `as: :file`, `as: :boolean` |
| `required:` | HTML required attr | `required: true` |
| `hint:` | Help text below the input | `hint: I18n.t('widget.form.name_hint')` |
| `wrapper:` | Override wrapper | `wrapper: :select`, `wrapper: :plain`, `wrapper: false` |
| `wrapper_html:` | HTML attrs on wrapper div | `wrapper_html: { class: 'mb-0' }` |
| `input_html:` | HTML attrs on input element | `input_html: { rows: 5, autocomplete: 'off' }` |
| `label_html:` | HTML attrs on label | `label_html: { class: 'sr-only' }` |
| `collection:` | Options for select | `collection: Status::VALUES.map { [it, it] }` |
| `label_method:` | Display text for collection | `label_method: :name` or `label_method: proc { \|r\| r.full_name }` |
| `value_method:` | Value for collection | `value_method: :id` |
| `include_blank:` | Blank option text | `include_blank: I18n.t('common.select_placeholder')` |

## Wrapper types

Configured in `config/initializers/simple_form.rb`:

| Wrapper | When to use |
|---------|-------------|
| `:default` | Text, number, date, textarea inputs — applied automatically |
| `:checkbox` | Boolean inputs — applied automatically via `wrapper_mappings` |
| `:select` | Select inputs — applied automatically via `wrapper_mappings`; also specify `wrapper: :select` when SimpleForm can't infer it |
| `:plain` | Full custom styling — no default input classes; pass all styling via `input_html:` |

Use `wrapper: false` to render the bare input with no wrapping div (e.g. inside a custom file-drop component).

## Select input

```slim
= form.input :status,
    as: :select,
    collection: Widget::STATUSES.map { |s| [I18n.t("widget.statuses.#{s}"), s] },
    label: I18n.t('widget.form.status'),
    include_blank: I18n.t('common.select')
```

For AR associations, pass a scope directly:

```slim
= form.input :user_profile_id,
    collection: current_user.user_profiles,
    label_method: :name,
    value_method: :id,
    include_blank: I18n.t('widget.form.select_profile'),
    label: I18n.t('widget.form.user_profile')
```

## Turbo form modal

Use the `turbo_form_modal` helper for modal create/edit forms. The `modal.form` accessor is the form object:

```slim
= turbo_form_modal( \
    model: @widget, \
    endpoint: @widget, \
    header_text: I18n.t("widget.#{action}.title"), \
    submit_text: I18n.t("widget.#{action}.submit")) do |modal|

  = modal.form.input :name, label: I18n.t('widget.form.name')

  = modal.form.input :category_id,
      collection: Category.all,
      label_method: :name,
      value_method: :id,
      include_blank: I18n.t('widget.form.select_category'),
      label: I18n.t('widget.form.category')
```

`turbo_form_modal` wires `data-controller="turbo-form"` automatically. The form submits via Turbo Stream.

## Select with inline "create new" link

When users may need to create the associated record on the fly, add `with_new_link:`:

```slim
= modal.form.input :category_id,
    collection: current_user.categories,
    label_method: :name,
    value_method: :id,
    include_blank: I18n.t('widget.form.select_category'),
    label: I18n.t('widget.form.category'),
    with_new_link: {
      link: helpers.link_to(I18n.t('category.new_link'),
              helpers.new_category_path,
              class: 'text-blue-600 underline hover:text-blue-700',
              data: { turbo_stream: true }),
      option_component: 'Category::Component::SelectOption'
    }
```

See the `select-with-new-link` skill for the full setup (TurboCallback, SelectOption component, etc.).

## File input with drag-and-drop

Use the `ApplyMate::Component::FileDrop` component — it renders the file input internally:

```slim
= render ApplyMate::Component::FileDrop.new(
    form: f,
    field: :attachment,
    accept: 'application/pdf',
    hint: I18n.t('widget.form.attachment_hint'),
    formats_label: 'PDF')
```

For a plain file input without the drop zone:

```slim
= form.file_field :logo,
    accept: 'image/*',
    class: 'block w-full text-sm text-gray-500 file:mr-4 file:py-2 file:px-4 file:rounded-lg file:border-0 file:text-sm file:font-semibold file:bg-indigo-50 file:text-indigo-700 hover:file:bg-indigo-100'
```

ActiveStorage file fields require `multipart: true` on the form tag. `turbo_form_modal` accepts `multipart: true` for this.

## Stimulus integration

**Before writing a custom Stimulus controller for form behaviour, check whether `turbo-form` already covers it.** It handles live field re-rendering, dependent selects, conditional sections, and live validation by re-fetching the form fragment from the server on any input/change event — no custom JS needed. See `.ai/docs/turbo_form_controller.md`.

Add Stimulus `data-action` attributes via `input_html:`:

```slim
/ Re-submit the form on input (live search / dependent field)
= form.input :query, input_html: { data: { action: 'input->turbo-form#update' } }

/ Swap dependent fields on change
= form.input :auth_method, as: :select,
    input_html: { data: { action: 'change->turbo-form#update' } }
```

## Hidden fields

Use `f.hidden_field` or `f.input … as: :hidden` — same golden rule as any other field:

```slim
= form.hidden_field :vacancy_id
= form.input :exclude_tags, as: :hidden, input_html: { data: { search_tags_target: 'tagsInput' } }
```

## Base errors

To display model-level (`errors[:base]`) errors inside the form:

```slim
- if f.object.errors[:base].any?
  = alert(text: f.object.errors[:base].first, type: :error)
```

## Skeleton: shared form component

```ruby
# app/concepts/widget/component/form.rb
class Widget::Component::Form < ApplyMate::Component::Base
  attr_reader :form
  def initialize(form:)
    @form = form
  end
end
```

```slim
/ app/concepts/widget/component/form.html.slim
= form.input :name, label: I18n.t('widget.form.name')
= form.input :description, as: :text, label: I18n.t('widget.form.description'), input_html: { rows: 5 }
```
