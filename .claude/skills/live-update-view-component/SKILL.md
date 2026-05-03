---
name: live-update-view-component
description: Instructions for creating a live-updatable ViewComponent without using JavaScript.
---

# Creating a Live-Updatable ViewComponent Without JavaScript

## Overview

This pattern lets a ViewComponent re-render itself in place whenever the user interacts with a form (types in an input, changes a select, clicks a button) — with no custom JavaScript. The trick is combining three existing pieces: a `turbo_frame_tag` that defines what gets replaced, the `turbo-form` Stimulus controller that listens for DOM events and fires a GET request, and an operation that re-normalises params and rebuilds the component's state. When the server responds, Turbo swaps the frame content. The browser history advances with the new URL when `turbo_action: 'advance'` is set on the frame. The canonical example in this codebase is `Vacancy::Component::SearchBar`, which live-updates a tag-based search filter without a single line of custom JS.

## When to Use

Use this pattern when **all** of the following are true:

- The UI needs to update in response to user input (filter, search, conditional field reveal, dependent select, live count).
- The new state can be derived entirely from the current form values (state lives in the URL/params, not in a hidden session key or WebSocket push).
- A full page reload would be acceptable as a fallback (the feature degrades gracefully).

Do **not** use this pattern when:

- The update is triggered by a background job or server event rather than a user action — use the `turbo-handler` skill instead.
- You need to upload files as part of the update — `turbo_form_controller` skips `File` fields.
- The component is inside a modal form created with `turbo_form_modal` — `turbo-form` is already wired by the modal helper; just add `data-action` to the relevant inputs.

## Architecture

```
User interacts with input/button
         │
         ▼
[turbo-form Stimulus controller]
  • Serialises entire form to URLSearchParams
  • Appends action_initiator_name=<field_name>
  • Cancels any in-flight request (AbortController)
  • GETs <turbo-form-url-value>?<params>
         │
         │  GET /vacancies?include_tags[]=ruby&new_include_tag=rails&action_initiator_name=new_include_tag
         ▼
[Rails controller]
  endpoint Vacancy::Operation::Index, Vacancy::Component::Index
         │
         ▼
[Operation]
  • Normalize params (merge new_tag into tags array, handle deletions, special actions)
  • Run sub-operations / query DB
  • self.model = ApplyMate::Operation::Struct.new(vacancies:, include_tags:, ...)
         │
         ▼
[Endpoint] spreads Struct keys as kwargs → Component.new(vacancies:, include_tags:, ...)
         │
         ▼
[Index component template]
  turbo_frame_tag 'vacancy-search' do
    render SearchBar.new(include_tags:, ...)   ← re-rendered with new state
    render List.new(vacancies:, ...)
         │
         ▼
[turbo-fetch utility]
  • Reads Turbo-Frame header, finds <turbo-frame id="vacancy-search"> in response
  • Replaces frame content in place — no full page reload
         │
         ▼
Browser URL bar updated (turbo_action: 'advance')
```

## Step-by-Step Implementation

### Step 1 — Create the outer "frame host" component

The frame host is typically the `Index` component. Its template wraps everything that should refresh inside a `turbo_frame_tag`. The frame id must be unique on the page.

```ruby
# app/concepts/vacancy/component/index.rb
class Vacancy::Component::Index < ApplyMate::Component::Base
  def initialize(vacancies:, applies_by_vacancy: {}, include_tags: nil, include_ops: nil, exclude_tags: nil, **)
    @vacancies = vacancies
    @applies_by_vacancy = applies_by_vacancy
    @include_tags = include_tags
    @include_ops = include_ops
    @exclude_tags = exclude_tags
  end
end
```

```slim
/ app/concepts/vacancy/component/index.html.slim
= helpers.turbo_frame_tag 'vacancy-search', data: { turbo_action: 'advance' } do
  = render Vacancy::Component::SearchBar.new(include_tags: @include_tags,
          include_ops: @include_ops,
          exclude_tags: @exclude_tags,
          count: @vacancies.total_entries)
  = render Vacancy::Component::List.new(vacancies: @vacancies, applies_by_vacancy: @applies_by_vacancy)
```

Key points:
- Always prefix Rails helpers with `helpers.` inside ViewComponent templates.
- `data: { turbo_action: 'advance' }` — each update pushes a new history entry so the user can bookmark filtered views and navigate with Back/Forward. Omit if URL history updates are not needed.
- Every child component rendered inside the frame re-renders on each update. Keep expensive renders behind Ruby conditionals when needed.

### Step 2 — Create the inner component with the form

The inner (filter/search) component holds the form. The form tag must have:
- `data-controller="turbo-form"` — mounts the Stimulus controller.
- `data-turbo-form-url-value` — the URL the controller GETs on update. Required when the form's HTML `action` differs from the live-update endpoint.
- `method: :get` — state lives in the URL.

```ruby
# app/concepts/vacancy/component/search_bar.rb
class Vacancy::Component::SearchBar < ApplyMate::Component::Base
  def initialize(include_tags: nil, include_ops: nil, exclude_tags: nil, count: nil)
    @include_tags = include_tags
    @include_ops  = include_ops
    @exclude_tags = exclude_tags
    @count        = count
  end

  private

  # State-aware helper — drives conditional rendering in the template
  def show_clear_filter?
    @show_clear_filter ||= !@include_tags.blank? || !@exclude_tags.blank? || !@include_ops.blank?
  end
end
```

```slim
/ app/concepts/vacancy/component/search_bar.html.slim
= helpers.simple_form_for :vacancy_search, url: helpers.vacancies_path, method: :get,
    html: { data: { turbo: true, controller: 'turbo-form', 'turbo-form-url-value': helpers.vacancies_path } } do |f|

  / ... inputs (see Step 3)

  - if show_clear_filter?
    = boolean_link form: f,
            name: :clear_filter,
            label: I18n.t('vacancy.search.clear_filter'),
            checked: false,
            data: { action: 'change->turbo-form#update' }
```

The component receives the current filter state as constructor arguments (passed from the Index component, which received them from the operation). Private helper methods (`show_clear_filter?`, `show_save_default?`, etc.) use that state to drive conditional rendering. This is how the form re-renders with correct tag pills, checkbox states, and counts after each update.

### Step 3 — Add `data-action` to interactive elements

Every input or button that should trigger a re-render needs a `data-action` attribute pointing to `turbo-form#update`. The event prefix determines when the update fires.

**Text input — fires when user leaves the field (or presses Enter):**

```slim
= text_field_tag :new_include_tag, nil,
    data: { action: 'change->turbo-form#update' }
```

**Text input — fires on every keystroke (live search feel):**

```slim
= f.input :query,
    input_html: { data: { action: 'input->turbo-form#update' } }
```

**Select / radio / checkbox — fires on value change:**

```slim
= f.input :category, as: :select,
    input_html: { data: { action: 'change->turbo-form#update' } }
```

**Button — fires on click (`event.preventDefault` is called automatically):**

```slim
button data-action='click->turbo-form#update'
  = I18n.t('vacancy.search.add')
```

When rendering buttons from Ruby helpers (not directly in Slim), pass the data attribute as a hash:

```ruby
concat button(label: I18n.t('vacancy.search.add'),
              tag: :button,
              'data-action': 'click->turbo-form#update')
```

**Boolean link / toggle rendered as a hidden checkbox + label:**

```ruby
boolean_link(
  form: f,
  name: :include_ops,
  index: 0,
  checked: is_and,
  label: is_and ? I18n.t('vacancy.search.and') : I18n.t('vacancy.search.or'),
  data: { action: 'change->turbo-form#update' }
)
```

### Step 4 — Wire the operation

The operation normalises raw params into clean state, runs business logic, and builds the `ApplyMate::Operation::Struct` that the endpoint spreads as keyword arguments into the component constructor.

```ruby
# app/concepts/vacancy/operation/index.rb
class Vacancy::Operation::Index < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    authorize! Vacancy.new, :index?

    # 1. Normalise — merge transient form values into persistent arrays
    params = normalize_include_params(params)
    params = normalize_exclude_params(params)

    # 2. Handle special button actions before querying
    if params.dig(:vacancy_search, :save_as_default) == '1' && current_user
      current_user.update!(include_tags: params[:include_tags],
                           include_ops:  params[:include_ops],
                           exclude_tags: params[:exclude_tags])
    elsif params.dig(:vacancy_search, :load_default) == '1' && current_user
      params[:include_tags] = current_user.include_tags
      params[:include_ops]  = current_user.include_ops
      params[:exclude_tags] = current_user.exclude_tags
    elsif params.dig(:vacancy_search, :clear_filter) == '1'
      params[:include_tags] = nil
      params[:include_ops]  = nil
      params[:exclude_tags] = nil
    end

    # 3. Run sub-operation (actual DB/ES query)
    result    = run_operation Vacancy::Operation::Search, { params:, current_user: }
    vacancies = result.model

    # 4. Build composite model — keys become component constructor kwargs
    self.model = ApplyMate::Operation::Struct.new(
      vacancies:,
      applies_by_vacancy:,
      include_tags: params[:include_tags],
      include_ops:  params[:include_ops],
      exclude_tags: params[:exclude_tags]
    )
  end

  private

  def normalize_include_params(params)
    # Merge new_include_tag text field into include_tags array
    if params[:new_include_tag].present?
      params[:include_tags] = [*params[:include_tags], params[:new_include_tag]].compact_blank
      params[:include_ops]  = [*params[:include_ops], 'or']
    end

    # Handle tag deletion — find which delete button was pressed by index
    delete_tag_index = params.fetch(:include_delete_tag, {}).values.map(&:to_b).find_index(&:present?)
    if delete_tag_index
      params[:include_tags].delete_at(delete_tag_index)
      # adjust ops array based on delete position...
    end

    params
  end
end
```

`ApplyMate::Operation::Struct` is essential here. The `Html` endpoint detects `is_a?(ApplyMate::Operation::Struct)`, calls `.to_h`, and passes the resulting hash as keyword arguments to `Component.new(**view_options)`. This means every key in the struct must match a keyword argument in the component's `initialize` (or be absorbed by `**`).

### Step 5 — Wire the controller

Nothing special. One line:

```ruby
# app/controllers/vacancies_controller.rb
class VacanciesController < ApplicationController
  def index
    endpoint Vacancy::Operation::Index, Vacancy::Component::Index
  end
end
```

On a live-update GET, the browser sends `Turbo-Frame: vacancy-search`. The endpoint responds with an HTML fragment containing that frame, which Turbo uses to replace just that section of the page.

## Key Decisions

### GET vs POST

Always use `method: :get` for live-update forms. Filter/search state belongs in the URL — it makes the result bookmarkable, shareable, and navigable via the browser Back button. POST is for mutations (create, update, destroy).

### State in params vs session

Keep all filter state in params (the URL). The operation normalises transient params (e.g. `new_include_tag`) into persistent ones (e.g. `include_tags[]`) and returns the clean state in the struct. The component is reconstructed from scratch on every request — there is no client-side state to manage. This makes the component trivially testable and the URL always reflects the full view state.

### `data-turbo-form-url-value` — when is it required?

If `data-turbo-form-url-value` is not set, the controller infers the URL from the form action: it appends `/new` for POST forms or `/edit` for PUT/PATCH forms. For a `method: :get` form the action URL already is the correct endpoint, so the value is technically redundant — but setting it explicitly is defensive and matches the convention in this codebase.

### `turbo_action: 'advance'` for browser history

Add `data: { turbo_action: 'advance' }` to the `turbo_frame_tag` when filter changes should be reflected in the URL bar and history stack. Omit it for modals, inline editors, or any component where URL changes would be confusing.

## Event Trigger Guide

| Situation | Event | Example |
|-----------|-------|---------|
| Text input — update after the user finishes typing (blur or Enter) | `change` | Tag name field |
| Text input — update on every keystroke (live search) | `input` | Full-text search box |
| Select, radio, checkbox | `change` | Category select, auth method radio |
| Button (add tag, clear filter, load defaults) | `click` | "Add" button, "Clear filters" link |
| Boolean link / toggle (hidden checkbox + label) | `change` | AND/OR logic toggle between tags |

When in doubt, prefer `change` over `input` — `change` debounces naturally (fires once on blur or Enter) and avoids flooding the server on every keystroke.

## Reading `action_initiator_name` Server-Side

The controller appends `action_initiator_name` — the `name` attribute of the field that triggered the update. Read `params[:action_initiator_name]` in the operation to vary behaviour by field:

```ruby
def perform!(params:, current_user:, **)
  skip_authorize
  form = Widget::FormObject::Create.new(params[:widget])
  self.model = form

  # Only load subcategories when the category field changed
  if params[:action_initiator_name] == 'widget[category_id]'
    @subcategories = Subcategory.where(category_id: form.category_id)
  end
end
```

Common use cases:
- Load a dependent select's options only when the parent field changed (avoids unnecessary queries on every update).
- Differentiate between "user is typing a new tag" (`new_include_tag`) vs "user is deleting an existing tag" (`include_delete_tag[0]`) to apply different normalisation logic.
- Skip expensive computations when a lightweight field triggered the update.

The `name` attribute follows standard Rails parameter naming — for a `simple_form_for :widget` form, a field named `category_id` will have `name="widget[category_id]"`, so check for that exact string.

## Verification

### Manual end-to-end test

1. Start the server and open the page containing the live-update component.
2. Open DevTools Network tab, filter by Fetch/XHR.
3. Interact with a wired input — type in a text field, change a select.
4. Confirm a GET request fires to the correct URL with all form params serialised.
5. Confirm the response is 200 and contains a `<turbo-frame>` element with the correct id.
6. Confirm the frame content in the DOM updates without a full page reload (the `<html>` element should not flash).
7. If `turbo_action: 'advance'` is set, confirm the URL bar updates to include the new params.
8. Press Back — confirm the previous filter state is restored.

### Debugging guide

| Symptom | Likely cause |
|---------|-------------|
| Full page reload instead of frame swap | `turbo_frame_tag` id does not match the frame id the controller is targeting — check that the frame wraps the form |
| GET fires but content does not update | Server response does not contain a `<turbo-frame>` with the matching id — check the Index component template |
| No GET request fires at all | `data-controller="turbo-form"` missing or misspelled on the form tag; or `data-action` missing on the input |
| 404 on the GET request | `data-turbo-form-url-value` points to the wrong path; or the route does not accept GET |
| Component re-renders with wrong state | Operation not returning normalised state in the struct; check every struct key matches an `initialize` kwarg in the component |
| In-flight requests pile up | Already handled — `AbortController` in the Stimulus controller cancels the previous pending request on each new event |
