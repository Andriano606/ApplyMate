---
name: table
description: Instructions for adding or modifying table on the page. Use it when going to create or update table on the page.
---

# Create/Edit table on the page

## When to use
Use this skill whenever you need to create or modify table

## Rules
- Always use `ApplyMate::Component::Table` component for creating a new table.
- Component that implements a table should only have a `.rb` file (no `.html.slim` template).
- Table should be implemented in the `call` method.
- `edit_table_button` and `delete_table_button` helpers are available from `ApplyMate::Component::TableHelper` (included in `Base`).
- Always use `I18n.t()` (full form, not `t()`).

Example:
```ruby
# frozen_string_literal: true

class Vacancy::Component::Table < ApplyMate::Component::Base

  def initialize(vacancies:, **)
    @vacancies = vacancies
  end

  def call
    table = ApplyMate::Component::Table.new(rows: @vacancies, empty_message: I18n.t('vacancy.index.empty'))

    table.add_column(header: I18n.t('vacancy.table.name')) do |vacancy|
      helpers.content_tag(:span, vacancy.name, class: 'font-medium')
    end

    table.add_column(header: I18n.t('vacancy.table.status'), &:status)

    table.add_column(header: I18n.t('vacancy.table.actions'), type: :actions) do |vacancy|
      helpers.safe_join([
        edit_table_button(link: helpers.edit_vacancy_path(vacancy)),
        delete_table_button(link: helpers.vacancy_path(vacancy), confirm: I18n.t('vacancy.destroy.confirm'))
      ], ' ')
    end

    render table
  end
end
```