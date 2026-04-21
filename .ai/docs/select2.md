# Select2

Custom SimpleForm input (`Select2Input`) backed by a Stimulus controller. Supports static collections and dynamic AJAX loading.

## Usage

### Static collection

```slim
= f.input :material_ids,
    as: :select2,
    collection: materials,
    label_method: :name,
    label: false,
    input_html: { multiple: true }
```

### AJAX mode

Omit `collection:` and provide `ajax_url:` instead. The model is inferred from the attribute name (`material_ids` → `Material`).

```slim
= f.input :material_ids,
    as: :select2,
    ajax_url: admin_materials_path(format: :json),
    label_method: :name,
    label: false,
    input_html: { multiple: true }
```

The currently selected records are pre-loaded automatically from the form object's value — no `selected:` needed unless overriding.

### AJAX mode with a non-id value column

When the stored value is not the integer primary key (e.g. a `ref` UUID), pass `find_by:` so the pre-selected record can be looked up correctly on page load:

```slim
= f.input :nova_poshta_city_ref,
    as: :select2,
    ajax_url: nova_poshta_cities_path(format: :json),
    model_class: NovaPoshta::City,
    find_by: :ref,
    placeholder: I18n.t('select2.placeholder')
```

The model must implement `#select2_search_result` returning `{ id: ref, text: name }` so the value round-trips correctly.

### Explicit model class (when attribute name doesn't match)

```slim
= f.input :owner_id,
    as: :select2,
    ajax_url: users_path(format: :json),
    model_class: User
```

## Options

| Option | Description |
|---|---|
| `collection:` | Static collection. Mutually exclusive with `ajax_url:`. |
| `ajax_url:` | URL for dynamic AJAX search. Enables AJAX mode. |
| `label_method:` | Method called on each record for display text. Default: `:to_s`. Also used when pre-loading selected records. |
| `value_method:` | Method for option value. Default: `:id`. Static mode only. |
| `placeholder:` | Placeholder string. Falls back to `I18n.t("select2.<model>.placeholder")`. |
| `model_class:` | Explicit model class for AJAX mode. Inferred from attribute name if omitted. |
| `find_by:` | Column used to look up the pre-selected record in AJAX mode. Defaults to `:id`. Use `:ref` (or any other column) when the attribute value is not the integer primary key. |
| `selected:` | Override pre-selected value. Normally read from form object. |
| `include_blank:` | Adds blank option (static mode). AJAX mode adds it automatically. |
| `tags:` | Set `true` to allow free-text tag creation. |
| `input_html:` | HTML attributes on the `<select>`. Use `{ multiple: true }` for multi-select. |

## Making a model AJAX-searchable

### 1. Include the concern and declare the text method

```ruby
class Material < ApplicationRecord
  include Select2Searchable
  select2_text_method :name  # used by both JSON endpoint and pre-load
end
```

`select2_text_method :name` generates `#select2_search_result` → `{ id:, text: name }`.

For custom formatting override directly:

```ruby
def select2_search_result
  { id:, text: "#{code} — #{name}" }
end
```

### 2. Support search filtering in the Index operation

```ruby
class Admin::Material::Operation::Index < ApplyMate::Operation::Base
  def perform!(params:, current_user:)
    authorize! Material, :index?
    self.model = policy_scope(Material)
                 .then { |s| params[:search].present? ? s.where('name ILIKE ?', "%#{params[:search]}%") : s }
                 .order(:name)
                 .paginate(page: params[:page])
  end
end
```

Select2 sends `?search=<term>&page=<n>` automatically.

### 3. JSON response

The `endpoint` method in `OperationsMethods` handles JSON format automatically for any `index` action:

```json
{
  "result": [{ "id": 1, "text": "PLA" }, { "id": 2, "text": "PETG" }],
  "pagination": { "more": false }
}
```

No extra controller code needed — just ensure the route allows `format: :json`.

## Architecture

- **`app/inputs/select2_input.rb`** — SimpleForm input, handles both modes
- **`app/models/concerns/select2_searchable.rb`** — concern with `select2_text_method` DSL
- **`app/javascript/controllers/select2_controller.ts`** — Stimulus controller, initializes select2, handles AJAX transport and `change` event bubbling
- **`app/stylesheets/select2.css`** — Tailwind-matched theme (imported in `application.tailwind.css`)
