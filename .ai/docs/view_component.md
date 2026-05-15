# ViewComponent

All components inherit `ApplyMate::Component::Base < ViewComponent::Base`. Each component is a `.rb` class paired with a `.html.slim` template in the same directory.

## Quotes in templates

Use single quotes in `.html.slim` templates wherever possible — for CSS classes, string arguments, HTML attributes, etc. Only fall back to double quotes when interpolation is needed.

```slim
/ ✅ correct
span class='px-2 py-1 text-xs'
= helpers.link_to I18n.t('...'), helpers.root_path

/ ❌ avoid unless interpolation is required
span class="px-2 py-1 text-xs"
```

## Slim dot-shorthand limits with Tailwind

In Slim, the dot-shorthand (`.class-name`) breaks on `/` — Slim treats it as a comment delimiter. Any Tailwind class containing `/` (opacity modifiers, arbitrary fractions) must use an explicit `class=` attribute instead.

```slim
/ ❌ breaks — Slim stops parsing the tag at the first /
.bg-gray-800\/50.px-6.py-4

/ ✅ correct — use explicit attribute when any class contains /
div(class='bg-gray-800/50 px-6 py-4')
```

Common Tailwind classes that trigger this: `bg-*/50`, `text-black/70`, `ring-white/10`, `from-indigo-500/20`, etc. When in doubt, use `div(class='...')` for any container that mixes opacity-modifier classes with others.

## Calling Rails helpers in templates

Inside a ViewComponent `.html.slim`, Rails view helpers are **not** in scope by default. Always call them through `helpers.`:

```slim
/ ✅ correct
= helpers.turbo_frame_tag 'vacancy-search' do
  ...
= helpers.link_to I18n.t('...'), helpers.root_path
= helpers.image_tag item.logo, class: '...'

/ ❌ will raise NoMethodError
= turbo_frame_tag 'vacancy-search' do
  ...
```

This applies to any Rails helper: `turbo_frame_tag`, `link_to`, `image_tag`, `content_tag`, `tag`, `will_paginate`, etc. Helpers that are mixed into `ApplyMate::Component::Base` (e.g. `button`, `badge`, `icon`) are the exception — they are available directly without `helpers.`.

## Decision tree — before creating a component

**Step 1 — check if it already exists.**
Look in `app/concepts/apply_mate/component/helper.rb`. Every shared component has a helper method there (`button`, `link`, `badge`, `alert`, `accordion`, `tabs`, `turbo_form_modal`, `file_drop`, etc.). If a matching helper exists, use it — do not write raw HTML or call `helpers.link_to` / `helpers.content_tag` when a component covers the use case.

```slim
/ ✅ use the helper
= link(url: path, size: :sm) do
  = icon(:arrow_down_tray, size: 4)
  = I18n.t('...')

/ ❌ avoid — bypasses the shared component
= helpers.link_to path, class: 'inline-flex items-center ...'
  = icon(:arrow_down_tray, size: 4)
  = I18n.t('...')
```

**Step 2 — if it doesn't exist, decide whether it's reusable.**

| Will other concepts use this? | Where to put it |
|-------------------------------|-----------------|
| Yes — generic UI primitive (badge variant, modal wrapper, form widget, etc.) | `app/concepts/apply_mate/component/<name>.rb` + template, and add a helper method to `app/concepts/apply_mate/component/helper.rb` |
| No — specific to one resource | `app/concepts/<resource>/component/<name>.rb` + template, no helper needed |

When in doubt, prefer resource-scoped first. Promote to shared only when a second concept actually needs it.

## Shared component (reusable)

### 1. Create the class

```ruby
# app/concepts/apply_mate/component/status_badge.rb
class ApplyMate::Component::StatusBadge < ApplyMate::Component::Base
  def initialize(status:)
    @status = status
    super()
  end
end
```

### 2. Create the template

```slim
/ app/concepts/apply_mate/component/status_badge.html.slim
span class="px-2 py-1 text-xs font-medium rounded-full #{color_class}"
  = I18n.t("statuses.#{@status}")
```

### 3. Register in the helper

```ruby
# app/concepts/apply_mate/component/helper.rb
def status_badge(status:)
  render(ApplyMate::Component::StatusBadge.new(status:))
end
```

### 4. Use via helper (not `render` directly)

```slim
= status_badge(status: @vacancy.status)
```

## Resource-scoped component (not reusable)

No helper registration needed — just `render` it directly:

```ruby
# app/concepts/vacancy/component/score_chart.rb
class Vacancy::Component::ScoreChart < ApplyMate::Component::Base
  def initialize(vacancy:)
    @vacancy = vacancy
    super()
  end
end
```

```slim
/ app/concepts/vacancy/component/score_chart.html.slim
.chart ...
```

```slim
/ used only within vacancy templates
= render Vacancy::Component::ScoreChart.new(vacancy: @vacancy)
```

## Base class features

`ApplyMate::Component::Base` includes:

| Mixin | What it provides |
|-------|-----------------|
| `ApplyMate::Component::Helper` | `button`, `badge`, `alert`, `turbo_form_modal`, `file_drop`, etc. |
| `ApplyMate::Component::IconHelper` | `icon(:name, size:)` |
| `ApplyMate::Component::TableHelper` | `edit_table_button`, `delete_table_button`, etc. |
| `ApplyMate::Component::AdminMethodsHelper` | `available_for :admin` class macro + `render?` guard |
| `current_user` | Current signed-in user — **not available in `initialize`** |

## `current_user` and `before_render`

`current_user` uses `view_context`, which is only available during rendering — **not during `initialize`**. Do not call it in `initialize`.

For logic that needs `current_user` (e.g. scoping a DB query), use `before_render`:

```ruby
def initialize(vacancy:, **)
  @vacancy = vacancy
end

def before_render
  @apply = @vacancy.applies.where(user: current_user).last
end
```

### Components rendered via `ApplicationController.renderer` (broadcasts)

`ApplicationController.renderer.render_to_string(MyComponent.new(...))` has **no request context** — `current_user` returns `nil`. Components rendered this way must not rely on `current_user`.

**Pattern:** accept the record directly as a keyword argument (bypassing the lookup), and derive the user from it:

```ruby
LAZY = :lazy

def initialize(vacancy:, apply: LAZY, **)
  @vacancy = vacancy
  @apply_preset = apply
end

def before_render
  # In a normal request, look up by current_user.
  # In a broadcast (ApplicationController.renderer), apply: is passed directly.
  @apply = (@apply_preset == LAZY) ? @vacancy.applies.where(user: current_user).last : @apply_preset
end

private

def frame_user
  # @apply.user avoids calling current_user when apply is known (e.g. during broadcast)
  @apply.nil? ? current_user : @apply.user
end
```

Broadcast call passes the record explicitly:
```ruby
Apply::Component::StatusBadge.new(vacancy: vacancy, apply: apply)  # no current_user needed
```

## Slots

Use ViewComponent slots for components that accept inner content blocks:

```ruby
renders_one :header
renders_many :rows
```

### Rendering a slot in a template

**Never** use `render(slot_instance)` — it delegates `render_in` via `method_missing` without the content block, so the slot renders empty. Use `= slot_instance` instead, which calls `Slot#to_s` and correctly passes the block:

```slim
/ ✅ correct
= actions

/ ❌ silent empty output
= render(actions)
```

### `renders_many` with a lambda

Use a lambda when slots need access to parent state (instance variables). The lambda is bound to the parent component, so `@ivars` are available:

```ruby
renders_many :tabs, lambda { |label:|
  @index = (@index || 0) + 1
  Tab.new(label: label, url: "#{@base_url}?tab=#{@index}", active: @current == @index.to_s)
}
```

The block passed to `with_tab { ... }` is stored on the slot and forwarded to `render_in` via `Slot#to_s` — it does not need to be yielded inside the lambda.

### Inline slot component (no template)

For slots that just render their content block, define `call` returning `content`. No `.html.slim` needed:

```ruby
class MyComponent::Item < ApplyMate::Component::Base
  def initialize(label:)
    @label = label
  end

  def label
    @label
  end

  def call
    content
  end
end
```

Do not use `attr_reader` — expose methods explicitly (project style rule).

### Slot identity comparison in templates

`tab == shown` uses object identity (`BasicObject#==`) since `Slot` doesn't override `==`. This works reliably when both sides come from the same `tabs` array:

```slim
- shown = tabs.find(&:active?) || tabs.first
- tabs.each do |tab|
  = helpers.link_to tab.label, tab.url, class: tab == shown ? active_class : inactive_class
```

### Per-request counter with `before_render`

To generate unique IDs that are stable across requests (required for Turbo Frames), store state on `view_context` in `before_render` — it is fresh per request:

```ruby
def before_render
  n = (view_context.instance_variable_get(:@__tabs_counter) || 0) + 1
  view_context.instance_variable_set(:@__tabs_counter, n)
  @frame_id = "tabs_component_#{n}"
end
```

**Do not use `@@class_variables`** for this — they persist across requests, so Turbo Frame IDs in the page won't match IDs in the response, producing "Content missing".

### `helpers.params` in helper methods

In `ApplyMate::Component::Helper` methods, bare `params` is not in scope. Use `helpers.params`:

```ruby
# ✅ correct
def tabs(base_url:, &block)
  render(Tabs.new(base_url:, current: helpers.params['selected_tab']))
end

# ❌ raises NoMethodError
def tabs(base_url:, &block)
  render(Tabs.new(base_url:, current: params['selected_tab']))
end
```

## Skeleton

```ruby
class Widget::Component::Card < ApplyMate::Component::Base
  def initialize(widget:)
    @widget = widget
    super()
  end
end
```

```slim
/ widget/component/card.html.slim
.rounded-lg.border.border-gray-200.dark:border-gray-700.p-4
  h3.text-sm.font-medium.text-gray-900.dark:text-gray-100
    = @widget.name
```
