# Operations

Operations are plain Ruby service objects in `app/concepts/<resource>/operation/`. Every controller action calls exactly one operation via `endpoint(OperationClass, ComponentClass)`.

## Naming convention

**Operations must be named after the controller action.** Components should also match the action name by default, but may differ when the UI shape warrants it — the most common case is a modal component shared across `new`/`create` and `edit`/`update`.

| Controller action | Operation | Component |
|-------------------|-----------|-----------|
| `index` | `Resource::Operation::Index` | `Resource::Component::Index` |
| `new` / `create` | `Resource::Operation::Create` | `Resource::Component::New` or `Resource::Component::NewModal` |
| `edit` / `update` | `Resource::Operation::Update` | `Resource::Component::Edit` or `Resource::Component::EditModal` |
| `show` | `Resource::Operation::Show` | `Resource::Component::Show` |
| `destroy` | `Resource::Operation::Destroy` | — |

When the same modal form is used for both create and update, name it after the form's purpose rather than the action — e.g. `Resource::Component::FormModal`. Both `create` and `update` actions pass the same component to `endpoint`.

Sub-operations called internally (not directly by a controller) should be named after what they do, not an action name — e.g. `Vacancy::Operation::Search` for the ES query builder called from `Vacancy::Operation::Index`.

## Lifecycle

```ruby
class MyResource::Operation::Create < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    # 1. Build or find the model
    self.model = current_user.my_resources.build

    # 2. Authorize (mandatory — raises at runtime if omitted)
    authorize! model, :create?

    # 3. Validate params via form object and sync to model
    form = MyResource::FormObject::Create.new(params[:my_resource])
    parse_validate_sync(form, model)

    # 4. Persist
    model.save!

    # 5. Set flash message
    notice(I18n.t('my_resource.create.success'))
  end
end
```

The base class wraps `perform!` in a `rescue ActiveRecord::RecordInvalid`, so raising that inside `perform!` (e.g. from `parse_validate_sync`) marks the result as failed and copies errors.

## Authorization

Every operation must call one of these — the controller raises `Pundit::NotAuthorizedError` otherwise:

```ruby
authorize! model, :index?          # checks MyResourcePolicy#index?
authorize! model, :create?
authorize! model, :update?
authorize! model, :destroy?

policy_scope(MyResource)           # returns Pundit-scoped relation; also counts as authorizing
skip_authorize                     # explicitly bypass (e.g. public pages)
skip_policy_scope                  # bypass scope check when not using policy_scope
```

Custom policy or failure message:

```ruby
authorize! record, :publish?,
           policy: CustomPolicy.new(current_user, record),
           fail_message: I18n.t('errors.not_allowed')
```

## Result Object

`result` is an `ApplyMate::Operation::Result` instance:

```ruby
result.success?          # true when no errors and model.errors is empty
result.failure?          # opposite
result.model             # set by self.model =
result.notice            # { text:, level:, autohide: } hash
result[:any_key]         # arbitrary hash access, e.g. result[:pundit]
result.errors            # ActiveModel::Errors
result.sub_results       # array of nested operation results
```

## Error Handling

```ruby
add_error(:base, "Something went wrong")       # adds to result.errors[:base]
add_errors(model.errors)                       # bulk-copy from any AR errors object
```

Raising `ActiveRecord::RecordInvalid` anywhere inside `perform!` exits the operation cleanly — errors are copied to `result.errors` and `result.failure?` becomes true.

## Form Object Integration

```ruby
# Validates, syncs dirty props to model, raises RecordInvalid on failure
parse_validate_sync(form_object, model)

# Only validate, raise on failure (no sync)
validate_form_object(form_object)
```

See `.ai/docs/form_objects.md` for the full FormObject DSL.

## Sub-Operations

Compose operations:

```ruby
run_result = run_operation(OtherResource::Operation::DoThing, params:, current_user:)
# If OtherResource fails, its errors are merged into self.result and RecordInvalid is raised.

# To handle errors yourself:
run_result = run_operation(OtherResource::Operation::DoThing,
                           params:, current_user:,
                           manually_handle_errors: true)
if run_result.failure?
  add_error(:base, "Step failed")
  raise ActiveRecord::RecordInvalid
end
```

## ApplyMate::Operation::Struct

Use when the operation model is a composite view (not a single AR record):

```ruby
self.model = ApplyMate::Operation::Struct.new(
  vacancies:,
  applies_by_vacancy:,
  total_count: Source.count
)
```

The endpoint will spread struct keys as keyword arguments to the component constructor. Component receives `vacancies:`, `applies_by_vacancy:`, `total_count:` directly.

## Skeleton Templates

### Index (read-only)

```ruby
class Widget::Operation::Index < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    self.model = policy_scope(Widget).order(created_at: :desc)
                                     .paginate(page: params[:page])
    authorize! model, :index?
  end
end
```

### New (form prep)

```ruby
class Widget::Operation::New < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    self.model = Widget.new
    authorize! model, :new?
  end
end
```

### Create

```ruby
class Widget::Operation::Create < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    self.model = current_user.widgets.build
    authorize! model, :create?
    form = Widget::FormObject::Create.new(params[:widget])
    parse_validate_sync(form, model)
    model.save!
    notice(I18n.t('widget.create.success'))
  end
end
```

### Destroy

```ruby
class Widget::Operation::Destroy < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    self.model = current_user.widgets.find(params[:id])
    authorize! model, :destroy?
    model.destroy!
    notice(I18n.t('widget.destroy.success'))
  end
end
```
