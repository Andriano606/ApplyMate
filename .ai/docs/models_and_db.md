# Models & Database

## Nullable FK columns — use `dependent: :nullify` on the association

When a FK column is nullable (`null: true`, model side `optional: true`), add `dependent: :nullify` to the `has_many` (or `has_one`) on the parent model. ActiveRecord will NULL out the FK before destroying the parent, so no `PG::ForeignKeyViolation` is raised. Keep the DB FK as a plain restrict.

Generic example (`Widget` / `Part` are illustrative, not real models):

```ruby
# app/models/widget.rb — correct approach
has_many :parts, dependent: :nullify, inverse_of: :widget

# app/models/part.rb — model side must match
belongs_to :widget, optional: true

# migration — plain FK
add_foreign_key :parts, :widgets
```

Rule of thumb: **nullable FK → `dependent: :nullify` on the AR association; keep DB FK as default restrict.**

Exception: a circular reference such as `users.default_saved_filter_id` → `saved_filters` (`User belongs_to :default_saved_filter, optional: true`; `SavedFilter belongs_to :user`) uses `on_delete: :nullify` at the DB level (`db/schema.rb`), because destroying a user cascades to its saved filters while the user row still points at one of them.

## Inverse associations for non-standard FKs

When a model has multiple FKs to the same table, declare the `has_many` on the parent with explicit `foreign_key:` and `inverse_of:`. Generic example (`Message` has `sender_id` and `recipient_id`, both pointing at `users`):

```ruby
# app/models/user.rb
has_many :sent_messages,     class_name: 'Message', foreign_key: :sender_id,    dependent: :nullify, inverse_of: :sender
has_many :received_messages, class_name: 'Message', foreign_key: :recipient_id, dependent: :nullify, inverse_of: :recipient
```

`has_many` defines **instance** methods only — `User.sent_messages` is a `NoMethodError`; call `user.sent_messages`.

## Uniqueness validations — put errors on `:base`

`validates :user_id, uniqueness: { scope: :kind }` adds the error to `errors[:user_id]`. Since `user_id` has no form field, the error is invisible and the user sees no feedback. (A uniqueness validation on an attribute that **is** a form field, like `SavedFilter#name` scoped to `user_id`, is fine.)

For cross-field or ownership-based uniqueness use a custom `validate` method that adds to `:base` (generic `Widget` example):

```ruby
validate :unique_kind_per_user

def unique_kind_per_user
  return if user_id.blank? || kind.blank?
  return unless self.class.where(user_id:, kind:).where.not(id:).exists?

  errors.add(:base, I18n.t('widget.errors.kind_taken'))
end
```

`errors[:base]` is displayed by `turbo_form_modal` via `alert(text: f.object.errors[:base].first, type: :error)`.

## jsonb_accessor — setup and key naming rules

Use `jsonb_accessor` to declare typed accessors for jsonb columns (see `SavedFilter`, whose `vacancy_search` column exposes `include_tags`, `include_ops`, `exclude_tags`). It resolves types via `ActiveRecord::Type`, not `ActiveModel::Type`:

```ruby
jsonb_accessor :vacancy_search,
               include_tags: [ :string, array: true, default: [] ],
               exclude_tags: [ :string, array: true, default: [] ]
```

For unstructured values (arrays of hashes) jsonb_accessor 1.4.2 only knows primitive types, so register a passthrough type first (no such initializer exists in the repo today — add it when you need it):

```ruby
# config/initializers/jsonb_accessor_types.rb
ActiveRecord::Type.register(:value, ActiveModel::Type::Value)
```

**Naming rules:**
- Avoid `method` — it shadows `Object#method` which Rails uses internally. Use `http_method` and similar.
- When two jsonb columns share the same logical key, give the second column a distinct accessor name. The accessor name IS the JSON key, so renaming it later requires a data migration.

**Migration to rename a JSON key inside a jsonb column** (generic `widgets.settings` example):

```ruby
# Rename settings['method'] → settings['http_method']
execute <<~SQL
  UPDATE widgets
  SET settings = jsonb_set(settings - 'method', '{http_method}', settings->'method')
  WHERE settings ? 'method';
SQL
```

## upsert_all — deduplicate before calling

`upsert_all` with `ON CONFLICT DO UPDATE` raises `PG::CardinalityViolation` if the array contains two rows that conflict on the same unique key — PostgreSQL forbids updating the same row twice in one statement.

Always `.uniq` by the same columns as `unique_by:` before calling. `Vacancy.upsert_all` in `Vacancy::Operation::SyncVacancies` uses `unique_by: [:source_id, :external_id]`:

```ruby
# ❌ raises PG::CardinalityViolation when `rows` holds the same (source_id, external_id) twice
Vacancy.upsert_all(rows, unique_by: %i[source_id external_id], update_only: %i[title url])

# ✅ deduplicate by the same key first
rows = rows.uniq { |r| [r[:source_id], r[:external_id]] }
Vacancy.upsert_all(rows, unique_by: %i[source_id external_id], update_only: %i[title url])
```

Root cause is usually upstream dedup using a different column set than the DB constraint.
