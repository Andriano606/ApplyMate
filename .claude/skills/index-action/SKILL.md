---
name: index-action
description: Instructions for creating a full index action cycle (operation, component, table, controller, route, navbar, locales). Use when creating a new index page for a resource.
---

# Create a full index action

An index action consists of several pieces that must all be created together. Use the resource name (e.g. `Apply`, `Vacancy`) as `<Resource>` throughout.

## 1. Operation

Create `app/concepts/<resource>/operation/index.rb`. The operation is responsible for loading and scoping the collection. See the dedicated operation skill for full details — in short, it should:

- Use `policy_scope(<Resource>)` to scope records to the current user.
- Call `authorize! model, :index?`.
- Use `.paginate(page: params[:page])` for pagination.
- Use `.includes(...)` for any associations rendered in the table.

## 2. Policy

Create `app/policies/<resource>_policy.rb` with an `index?` method and a `Scope` inner class.

```ruby
# frozen_string_literal: true

class <Resource>Policy < ApplicationPolicy
  def index?
    user.present?
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      scope.where(user:)
    end
  end
end
```

## 3. Index component

Create `app/concepts/<resource>/component/index.rb` and `app/concepts/<resource>/component/index.html.slim`.

The `.rb` class holds initialization and a private `header_opts` method. Reference instance variables directly — no `attr_reader`.

```ruby
# frozen_string_literal: true

class <Resource>::Component::Index < ApplyMate::Component::Base
  def initialize(<resources>:, **)
    @<resources> = <resources>
  end

  private

  def header_opts
    { title: I18n.t('<resource>.index.title') }
  end
end
```

The `.html.slim` template renders the header and delegates to the table component:

```slim
= header(**header_opts)

= render <Resource>::Component::Table.new(<resources>: @<resources>)
```

If there is a "New" button, add it via the header slot:

```slim
= header(**header_opts) do |h|
  - h.with_buttons do
    = helpers.link_to I18n.t('<resource>.index.new'), helpers.new_<resource>_path, \
      data: { turbo_stream: true }, \
      class: 'inline-flex items-center px-4 py-2 text-sm font-medium ' \
             'text-white bg-indigo-600 rounded-lg hover:bg-indigo-700 transition-colors'

= render <Resource>::Component::Table.new(<resources>: @<resources>)
```

## 4. Table component

Create `app/concepts/<resource>/component/table.rb`. See the dedicated table skill for full details. The table component has only a `.rb` file (no template) and implements everything in `call`.

```ruby
# frozen_string_literal: true

class <Resource>::Component::Table < ApplyMate::Component::Base
  def initialize(<resources>:, **)
    @<resources> = <resources>
  end

  def call
    table = ApplyMate::Component::Table.new(rows: @<resources>, empty_message: I18n.t('components.table.empty'))

    table.add_column(header: I18n.t('<resource>.index.table.<column>')) do |record|
      helpers.content_tag(:span, record.<attribute>, class: 'font-medium')
    end

    # Add more columns as needed...

    render table
  end
end
```

## 5. Controller

Create `app/controllers/<resources>_controller.rb`. The index action is a single `endpoint` call — no logic in the controller.

```ruby
# frozen_string_literal: true

class <Resources>Controller < ApplicationController
  def index
    endpoint <Resource>::Operation::Index, <Resource>::Component::Index
  end
end
```

## 6. Route

Add the resource to `config/routes.rb`:

```ruby
resources :<resources>, only: [:index]
```

## 7. Navbar item (optional)

If the page should be accessible from the user dropdown, add an item to `build_items` in `app/concepts/apply_mate/component/navbar.rb`, inside the `:user_menu` section, before the divider that precedes Sign Out:

```ruby
Item.new(
  label: I18n.t('navbar.<key>'),
  path: helpers.<resources>_path,
  section: :user_menu,
  render: signed_in? && !impersonating?,
  icon: :<icon>
)
```

Available icons: `user`, `sparkles`, `clipboard_list`, `users`, `eye`, `clock`, `send`, `cube`, `bell`, `refresh`, `paperclip`, `lock_closed`, `chat_bubble`, `external_link`.

## 8. Locales

Add all keys used in the new files to `config/locales/uk.yml`. Minimum required:

```yaml
<resource>:
  index:
    title: <Ukrainian title>
    table:
      <column>: <Ukrainian header>
navbar:
  <key>: <Ukrainian label>
```

## Checklist

- [ ] `app/concepts/<resource>/operation/index.rb`
- [ ] `app/policies/<resource>_policy.rb`
- [ ] `app/concepts/<resource>/component/index.rb`
- [ ] `app/concepts/<resource>/component/index.html.slim`
- [ ] `app/concepts/<resource>/component/table.rb`
- [ ] `app/controllers/<resources>_controller.rb`
- [ ] `config/routes.rb` updated
- [ ] `config/locales/uk.yml` updated
- [ ] Navbar item added (if needed)
