---
name: view-component
description: Instructions for creating/updating view component. Use when create/update view_component class.
---

# Create/Edit view component

## Rules
- When adding UI elements (buttons, badges, icons, alerts, etc.) in a slim template, always check `app/concepts/apply_mate/component/helper.rb` first. It exposes helper methods (`badge`, `button`, `alert`, `header`, `radio_button`, etc.) that render shared components — use these instead of writing raw HTML.
- Always start with `# frozen_string_literal: true`.
- Inherit from `ApplyMate::Component::Base`.
- Do not use `attr_reader` or `attr_accessor` — reference instance variables directly (`@var`).
- File path convention: `app/concepts/<namespace>/component/<name>.rb` (and `<name>.html.slim` if a template is needed).
- Always use `I18n.t()` (full form, not `t()`).
- Never use `record.id` in route helpers or expose numeric IDs in URLs. All models include `Hashid::Rails` (via `ApplicationRecord`), which overrides `to_param` — pass the model directly to route helpers (e.g. `helpers.edit_vacancy_path(vacancy)`) or use `record.hashid` explicitly when needed.

## Example: component with `call` (no template)

Use `call` when the output is simple enough to build in Ruby (e.g. delegating to a helper).

```ruby
# frozen_string_literal: true

class Vacancy::Component::StatusBadge < ApplyMate::Component::Base

  def initialize(vacancy:, **)
    @vacancy = vacancy
  end

  def call
    badge(label: I18n.t("vacancy.status.#{@vacancy.status}"), color: @vacancy.active? ? :green : :gray)
  end
end
```

## Example: component with `.html.slim` template

Use a slim template when the component renders meaningful markup. The `.rb` file holds only initialization; the template references `@var` directly.

`app/concepts/vacancy/component/search_bar.rb`:
```ruby
# frozen_string_literal: true

class Vacancy::Component::SearchBar < ApplyMate::Component::Base

  def initialize(query: nil, count: nil, **)
    @query = query
    @count = count
  end
end
```

`app/concepts/vacancy/component/search_bar.html.slim`:
```slim
.max-w-7xl.mx-auto.pt-8.pb-4
  .flex.gap-2
    input.flex-1.rounded-lg.border.border-gray-300.px-4.py-2(
      value=@query
      placeholder=I18n.t('vacancy.search.placeholder')
    )
  - if @count
    p.text-sm.text-gray-500.mt-2 = I18n.t('vacancy.search.results_count', count: @count)
```