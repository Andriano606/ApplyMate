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
6. If `data-turbo-form-history-value="true"` is set and the response rendered
   successfully, writes the fetched URL into the address bar (see below).

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

## Excluding inputs from the GET request

Add `data-turbo-form-exclude` to any input that should **not** be serialised into the GET params on `update`. The field value is still submitted normally on the real form POST/PATCH — it is only omitted from live re-render requests.

Typical use: large textarea content that would bloat the URL but doesn't drive any conditional rendering.

```slim
= f.input :content,
    as: :text,
    input_html: { data: { turbo_form_exclude: true } }
```

Rails renders this as `data-turbo-form-exclude="true"` on the `<textarea>`.

## Custom fetch URL

If the re-render target differs from the form action (e.g. a search endpoint):

```slim
= helpers.simple_form_for @search, url: helpers.widgets_path,
    html: { data: { controller: 'turbo-form', 'turbo-form-url-value': helpers.new_widget_path } } do |f|
```

## Address-bar sync (`data-turbo-form-history-value`)

Opt-in. When set to `true` on the form, every successful `update` calls
`history.replaceState` with the exact URL it just fetched, so the address bar
keeps reproducing the on-screen state:

```slim
= helpers.simple_form_for :vacancy_search, url: helpers.vacancies_path, method: :get,
    html: { data: { controller: 'turbo-form', 'turbo-form-url-value': helpers.vacancies_path,
                    'turbo-form-history-value': true } } do |f|
```

Enable it **only** for forms whose GET request *is* the page's canonical URL
(e.g. the vacancy search bar). It is what makes these work mid-edit:

- **hard reload / share the link** — re-renders exactly the visible state;
- **`turbo_stream.action(:refresh, …)`** — the endpoint's default create/update
  response re-fetches the current location, so controllers that save state
  related to the form (e.g. `SavedFiltersController`) can rely on the default
  handling instead of hand-rolled turbo streams.

`replaceState` does not touch history entries (Back still leaves the page) and
is skipped when the fetch failed or was aborted, so the URL never points at a
state the browser did not render.

Leave it off for modal/auxiliary forms — their `update` fetches a fragment URL
(`…/new?…`) that must not become the page address.

## What turbo-form replaces

Before reaching for a custom Stimulus controller, check whether the requirement fits one of these patterns:

| Requirement | turbo-form solution |
|-------------|---------------------|
| Show/hide a field based on another field's value | `change->turbo-form#update` on the controlling field; render or skip the dependent field server-side |
| Populate a dependent select (e.g. subcategories after picking a category) | Same — return updated `<select>` options in the re-rendered fragment |
| Live validation hint | `input->turbo-form#update`; render the error/hint in the component |
| Toggle an optional form section | `click->turbo-form#update` on a button; render the section conditionally |
| Auto-submit a filter/search form on change | `change->turbo-form#update` (or `input->`) with no submit button |
