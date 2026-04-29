# Form Objects

Form objects in `app/concepts/<resource>/form_object/` wrap raw params before syncing to AR models. They inherit `ApplyMate::FormObject::Base` which includes `ActiveModel::Model`.

## Property DSL

```ruby
class Widget::FormObject::Create < ApplyMate::FormObject::Base
  # Simple scalar properties
  property :name
  property :description

  # Shorthand for multiple properties
  properties :title, :url, :status

  # With options
  property :slug,      default_value: -> { SecureRandom.hex(4) }
  property :notes,     virtual: true          # not synced to AR model
  property :avatar,    attachment: true        # ActiveStorage — requires open DB transaction when syncing
  property :role,      required_privilege: :admin  # gated by user privilege

  # Validations work normally
  validates :name, presence: true
  validates :url, format: { with: URI::DEFAULT_PARSER.make_regexp }
end
```

**`virtual: true`** — property is validated/read but never written to the AR model via `sync_to`.

**`attachment: true`** — marks the field as an ActiveStorage attachment. `sync_to` will raise if called outside a database transaction.

## Nested Forms

### has_many (collection)

```ruby
class Invoice::FormObject::Create < ApplyMate::FormObject::Base
  property :title

  has_many :line_items, form: LineItem::FormObject::Create,
                        reject_if: ->(item) { item.amount.blank? }
end
```

Params must use `line_items_attributes:` key (Rails nested attributes convention):

```ruby
# Array form (from JSON or custom params)
{ line_items_attributes: [{ amount: "100" }, { amount: "200" }] }

# Hash form (from HTML forms)
{ line_items_attributes: { "0" => { amount: "100" }, "1" => { amount: "200" } } }
```

### has_one / belongs_to

```ruby
class Apply::FormObject::Create < ApplyMate::FormObject::Base
  belongs_to :user_profile, form: UserProfile::FormObject::Nested
end
```

Params use `user_profile_attributes:` key.

## Sync Lifecycle

Inside an operation, call `parse_validate_sync(form, model)`:

1. Checks `form.valid?` (validates form + all nested subforms recursively)
2. Calls `form.sync_to(model)` — writes only **dirty properties** (those set from params) to the AR model
3. Calls `model.validate` if the form was valid
4. Raises `ActiveRecord::RecordInvalid` if any errors exist

`sync_to` handles:
- Plain attributes: `model.name = form.name`
- `belongs_to` associations: resolves by hashid or integer id
- Nested subforms: recursively syncs to associated AR records (build if new)

## Attachment Validation

```ruby
class Document::FormObject::Create < ApplyMate::FormObject::Base
  property :file, attachment: true

  validate_attachment :file,
    attachment_type: :pdf,     # or :image, :zip, etc.
    max_size_mb: 10,
    required: true,
    base_error: false          # true → errors added to :base instead of :file
end
```

When `attachment: true`, the operation must wrap `parse_validate_sync` + `model.save!` in a transaction:

```ruby
ApplicationRecord.transaction do
  parse_validate_sync(form, model)
  model.save!
end
```

## Initialization

```ruby
# From controller params (ActionController::Parameters are converted via to_unsafe_h)
form = Widget::FormObject::Create.new(params[:widget])

# Pre-populate from existing AR record (edit form)
form = Widget::FormObject::Update.new(params[:widget], existing_widget)
```

When a model is passed, the form reads current values from the model first, then overlays params on top.

## Skeleton Templates

### Flat form (create)

```ruby
class Widget::FormObject::Create < ApplyMate::FormObject::Base
  properties :name, :description, :status

  validates :name, presence: true
end
```

### Form with nested collection (create)

```ruby
class Order::FormObject::Create < ApplyMate::FormObject::Base
  property :customer_name

  has_many :items, form: Order::FormObject::Item,
                   reject_if: ->(item) { item.product_id.blank? }

  validates :customer_name, presence: true
end

class Order::FormObject::Item < ApplyMate::FormObject::Base
  property :product_id
  property :quantity, default_value: 1

  validates :product_id, :quantity, presence: true
end
```
