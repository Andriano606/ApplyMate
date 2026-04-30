# ViewComponent

All components inherit `ApplyMate::Component::Base < ViewComponent::Base`. Each component is a `.rb` class paired with a `.html.slim` template in the same directory.

## Decision tree — before creating a component

**Step 1 — check if it already exists.**
Look in `app/concepts/apply_mate/component/helper.rb`. Every shared component has a helper method there (`button`, `badge`, `alert`, `accordion`, `turbo_form_modal`, `file_drop`, etc.). If a matching helper exists, use it — do not create a duplicate.

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
| `current_user` | Current signed-in user |

## Slots

Use ViewComponent slots for components that accept inner content blocks:

```ruby
renders_one :header
renders_many :rows
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
