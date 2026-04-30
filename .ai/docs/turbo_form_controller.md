# turbo-form Stimulus Controller

`app/javascript/controllers/turbo_form_controller.ts`

Augments a form for two things:
1. **Live re-render** — on any `input`/`change`/`click` event, re-fetches the form fragment from the server with current field values so dependent fields, conditional sections, or validation hints update in place.
2. **Submit-button management** — disables the submit button on `turbo:submit-start` and re-enables it only on failure (prevents double-submit; leaves it disabled on success so the modal/page transition feels instant).

## Wiring the controller

Add `data-controller="turbo-form"` to the `<form>` tag. `turbo_form_modal` does this automatically. For a standalone form:

```slim
= helpers.simple_form_for @widget, url: helpers.widgets_path,
    html: { id: 'widget-form', data: { controller: 'turbo-form' } } do |f|
```

## `update` action — live re-render

Trigger it on any input that should cause the form to refresh:

```slim
/ Re-render on text input (debounced by browser's input event)
= f.input :query, input_html: { data: { action: 'input->turbo-form#update' } }

/ Re-render immediately on select change
= f.input :category, as: :select,
    input_html: { data: { action: 'change->turbo-form#update' } }

/ Re-render on button click (e.g. a toggle — preventDefault is called automatically)
button data-action="click->turbo-form#update"
  = I18n.t('widget.form.toggle_advanced')
```

When `update` fires it:
1. Serialises the entire form (minus file fields).
2. Appends `action_initiator_name` — the triggering field's `name` — so the server knows which field changed.
3. GETs `<form-action>/new` (create form) or `<form-action>/edit` (update form), or a custom URL if `data-turbo-form-url-value` is set.
4. Replaces the nearest `<turbo-frame>` ancestor with the response fragment.
5. Cancels any in-flight request before starting a new one (AbortController).

The operation reads `params[:action_initiator_name]` when it needs to vary behaviour by field:

```ruby
def perform!(params:, current_user:, **)
  skip_authorize
  form = Widget::FormObject::Create.new(params[:widget])
  self.model = form

  if params[:action_initiator_name] == 'category_id'
    @subcategories = Subcategory.where(category_id: form.category_id)
  end
end
```

## Custom fetch URL

If the re-render target differs from the form action (e.g. a search endpoint):

```slim
= helpers.simple_form_for @search, url: helpers.widgets_path,
    html: { data: { controller: 'turbo-form', 'turbo-form-url-value': helpers.new_widget_path } } do |f|
```

## What turbo-form replaces

Before reaching for a custom Stimulus controller, check whether the requirement fits one of these patterns:

| Requirement | turbo-form solution |
|-------------|---------------------|
| Show/hide a field based on another field's value | `change->turbo-form#update` on the controlling field; render or skip the dependent field server-side |
| Populate a dependent select (e.g. subcategories after picking a category) | Same — return updated `<select>` options in the re-rendered fragment |
| Live validation hint | `input->turbo-form#update`; render the error/hint in the component |
| Toggle an optional form section | `click->turbo-form#update` on a button; render the section conditionally |
| Auto-submit a filter/search form on change | `change->turbo-form#update` (or `input->`) with no submit button |
