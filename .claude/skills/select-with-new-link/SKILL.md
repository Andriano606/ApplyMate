---
name: select-with-new-link
description: Instructions for adding a select input with an inline "create new record" link. Use when a form has a select/association field and users may need to create the associated record on the spot — clicking the link opens a modal, filling it inserts the new option into the select automatically via TurboCallback.
---

# Select with Inline "Create New" Link

This pattern lets users create a missing record directly from a select field without leaving the page. They click a link below the select, a modal opens, they fill and submit, and the just-created option is automatically inserted and selected — all via the existing `TurboCallback` + `SimpleForm::WithNewLink` infrastructure.

## How it works (briefly)

`SimpleForm::WithNewLink` signs a `turbo_callback` parameter into the new-record link's URL. When the modal form is submitted, `TurboCallback` in `ApplyMate::Endpoint::TurboStream` intercepts the request, renders your `SelectOption` component, and returns two turbo stream actions: `close_active_modal` + `select_option` (appends the `<option>` and selects it).

---

## Step 1 — Create the SelectOption component

`app/concepts/<resource>/component/select_option.rb`

```ruby
# frozen_string_literal: true

class Resource::Component::SelectOption < ApplyMate::Component::Base
  def initialize(resource:)
    @resource = resource
  end

  def call
    tag.option(@resource.name, value: @resource.id)
  end
end
```

**Critical: keyword arg name rule**

The `TurboCallback` concern instantiates this component using `model_name.to_sym => model`, where `model_name` is `concept_underscored_class_name` — the last namespace segment before `Component`, underscored:

| Component class | Keyword arg |
|---|---|
| `SourceProfile::Component::SelectOption` | `source_profile:` |
| `BankAccount::Component::SelectOption` | `bank_account:` |
| `Salary::Employee::Component::SelectOption` | `employee:` |

The `call` method must return a plain `<option>` tag. Add `data-*` attributes if downstream JS needs them (e.g., for Stimulus controllers reacting to the `change` event dispatched after insertion).

---

## Step 2 — Verify controller new + create actions

Both actions must use `endpoint` with the Modal component. The `TurboCallback` interception is automatic — no extra code needed.

```ruby
class ResourcesController < ApplicationController
  def new
    endpoint Resource::Operation::New, Resource::Component::Modal
  end

  def create
    endpoint Resource::Operation::Create, Resource::Component::Modal
  end
end
```

---

## Step 3 — Verify routes

```ruby
resources :resources, only: [:new, :create]
```

---

## Step 4 — Add `with_new_link` to the parent form

**Association select** (most common — SimpleForm infers collection from the model):

```slim
= f.association :resource,
    as: :select,
    wrapper: :select,
    with_new_link: {
      link: helpers.link_to(I18n.t('resource.new_link'), helpers.new_resource_path, data: { turbo_stream: true }),
      option_component: 'Resource::Component::SelectOption'
    }
```

**Plain input select** (when you need explicit collection control):

```slim
= f.input :resource_id,
    as: :select,
    wrapper: :select,
    collection: current_user.resources.map { |r| [r.name, r.id] },
    with_new_link: {
      link: helpers.link_to(I18n.t('resource.new_link'), helpers.new_resource_path, data: { turbo_stream: true }),
      option_component: 'Resource::Component::SelectOption'
    }
```

**Key points:**

- The link **must** use `data: { turbo_stream: true }`, not `data: { turbo_frame: "..." }`. This makes Turbo send the request with the turbo-stream Accept header, so the server responds with stream actions that create the modal container inside `#turbo-modals` and render the modal into it.
- `option_component` is the full class name as a **string** — it is constantized at callback time in `TurboCallback`.
- The `#turbo-modals` frame is already in the application layout — nothing to add to the page.
- Any extra options inside `with_new_link:` (besides `:link`) are signed and passed to your `SelectOption` component as the `options` hash (currently unused by the concern, but available if you extend it).

---

## Checklist

- [ ] `app/concepts/<resource>/component/select_option.rb` created
  - [ ] Keyword arg name matches `concept_underscored_class_name` (last module before `Component`, underscored)
  - [ ] `call` returns `tag.option(name, value: id)` — a plain `<option>` tag, nothing else
- [ ] Controller `new` and `create` both use `endpoint ... , Resource::Component::Modal`
- [ ] Route for `new` + `create` exists
- [ ] `with_new_link:` in the form has:
  - [ ] `link:` using `data: { turbo_stream: true }` (not turbo-frame)
  - [ ] `option_component:` set to the full class name string
