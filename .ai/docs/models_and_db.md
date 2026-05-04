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
