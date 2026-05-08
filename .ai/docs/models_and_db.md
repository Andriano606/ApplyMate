# Models & Database

## Nullable FK columns — use `dependent: :nullify` on the association

When a FK column is nullable (`null: true`, model side `optional: true`), add `dependent: :nullify` to the `has_many` (or `has_one`) on the parent model. ActiveRecord will NULL out the FK before destroying the parent, so no `PG::ForeignKeyViolation` is raised. DB-level `on_delete: :nullify` is **not** needed and should be avoided — keep FK constraints as plain restrict.

```ruby
# app/models/prompt.rb — correct approach
has_many :fill_form_applies,   class_name: 'Apply', foreign_key: :fill_form_prompt_id,   dependent: :nullify, inverse_of: :fill_form_prompt
has_many :generate_cv_applies, class_name: 'Apply', foreign_key: :generate_cv_prompt_id, dependent: :nullify, inverse_of: :generate_cv_prompt
```

```ruby
# app/models/apply.rb — model side must match
belongs_to :fill_form_prompt, class_name: 'Prompt', optional: true
```

```ruby
# migration — plain FK, no on_delete rule
add_foreign_key :applies, :prompts, column: :fill_form_prompt_id
```

Rule of thumb: **nullable FK → `dependent: :nullify` on the AR association; keep DB FK as default restrict.**

## Inverse associations for non-standard FKs

When a model has multiple FKs to the same table (e.g. `applies.fill_form_prompt_id` and `applies.generate_cv_prompt_id` both point to `prompts`), declare the `has_many` on the parent with explicit `foreign_key:` and `inverse_of:`:

```ruby
# app/models/prompt.rb
has_many :fill_form_applies,   class_name: 'Apply', foreign_key: :fill_form_prompt_id,   dependent: :nullify, inverse_of: :fill_form_prompt
has_many :generate_cv_applies, class_name: 'Apply', foreign_key: :generate_cv_prompt_id, dependent: :nullify, inverse_of: :generate_cv_prompt
```

`has_many` defines **instance** methods only — `Prompt.fill_form_applies` is a `NoMethodError`; call `prompt.fill_form_applies`.

## Uniqueness validations — put errors on `:base`

`validates :user_id, uniqueness: { scope: :prompt_type }` adds the error to `errors[:user_id]`. Since `user_id` has no form field, the error is invisible and the user sees no feedback.

Always use a custom `validate` method that adds to `:base` for cross-field or ownership-based uniqueness:

```ruby
validate :unique_type_per_user

def unique_type_per_user
  return if user_id.blank? || prompt_type.blank?
  return unless self.class.where(user_id:, prompt_type:).where.not(id:).exists?

  errors.add(:base, I18n.t('prompt.errors.type_taken'))
end
```

`errors[:base]` is displayed by `turbo_form_modal` via `alert(text: f.object.errors[:base].first, type: :error)`.

## jsonb_accessor — setup and key naming rules

Use `jsonb_accessor` to declare typed accessors for jsonb columns. It resolves types via `ActiveRecord::Type`, not `ActiveModel::Type`.

**Registering a passthrough type for arrays/hashes** — jsonb_accessor 1.4.2 only knows primitive types (`:string`, `:integer`, etc.). For unstructured values (arrays of hashes) register `:value` in an initializer:

```ruby
# config/initializers/jsonb_accessor_types.rb
ActiveRecord::Type.register(:value, ActiveModel::Type::Value)
```

Then use it in the model:

```ruby
jsonb_accessor :form_data,
  action:           :string,
  http_method:      :string,   # see naming rules below
  submit_selector:  :string,
  external_url:     :string,
  trigger_selector: :string,
  cookies:          :string,
  inputs:           :value     # Array of hashes — passthrough type

jsonb_accessor :filled_form_data,
  filled_inputs: :value        # different name avoids clash with form_data.inputs
```

**Naming rules:**
- Avoid `method` — it shadows `Object#method` which Rails uses internally. Use `http_method` and rename the JSON key in a migration.
- When two jsonb columns share the same logical key (e.g. both store `inputs`), give the second column a distinct accessor name (`filled_inputs`). The accessor name IS the JSON key, so a migration is required to rename the existing data.

**Migration to rename a JSON key inside a jsonb column:**

```ruby
# Rename form_data['method'] → form_data['http_method']
execute <<~SQL
  UPDATE applies
  SET form_data = jsonb_set(form_data - 'method', '{http_method}', form_data->'method')
  WHERE form_data ? 'method';
SQL
```

## Per-resource default (one default per parent per user)

When a user can have multiple records of type X but only one default per source/context, use a boolean column with a partial unique index — **not** a FK column on the user.

```ruby
# migration
add_column :source_profiles, :is_default, :boolean, default: false, null: false
add_index  :source_profiles, [:user_id, :source_id],
           unique: true,
           where:  '"is_default" = true',
           name:   'index_source_profiles_on_user_source_default'
```

```ruby
# model
def self.default_for(user, source)
  find_by(user: user, source: source, is_default: true)
end

def set_as_default!
  SourceProfile.transaction do
    SourceProfile.where(user: user, source: source, is_default: true)
                 .where.not(id: id)
                 .update_all(is_default: false)
    update!(is_default: true)
  end
end
```

The partial unique index enforces the constraint at the DB level — only one row per `(user_id, source_id)` can have `is_default = true`. Rows with `is_default = false` are unconstrained.
