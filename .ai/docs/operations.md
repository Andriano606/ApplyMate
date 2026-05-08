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

**Only `errors[:base]` is visible in the UI.** `turbo_form_modal` renders `f.object.errors[:base].first` as an alert banner — errors on any other attribute (e.g. `errors[:user_id]`) are silently swallowed. Model-level validations that use `validates :field, uniqueness: ...` add errors to that field, not `:base`. Use a custom `validate` method and `errors.add(:base, ...)` for any cross-field or ownership constraint that must surface to the user. See `.ai/docs/models_and_db.md`.

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

The basic skeleton works for simple forms. **If the form contains any field that triggers `turbo-form#update` (radio buttons, dependent selects, etc.), the `New` operation must also read params and sync them to the model.** Without this, every re-render rebuilds a blank model, so radio buttons never appear selected and dependent sections never update.

```ruby
# Simple form — no turbo-form re-renders needed
class Widget::Operation::New < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    self.model = Widget.new
    authorize! model, :new?
  end
end
```

```ruby
# Form with radio buttons / dependent fields — must sync params on re-render
class Widget::Operation::New < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    self.model = current_user.widgets.build

    if params[:widget].present?
      form_object = Widget::FormObject::Create.new(params[:widget])
      form_object.sync_to model
    end

    authorize! model, :new?
  end
end
```

Use `form_object.some_field ||= default_value` after `sync_to` to pre-select a default on first open (when params are absent).

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

## Logging in background jobs — log in the operation, not the job

When a job delegates to an operation, summary logs about what the operation fetched/produced belong in `perform!`, not in the job's `perform`. The job only knows about validation/persistence; the operation knows what it actually fetched.

```ruby
# ✅ in the operation
def perform!(**)
  proxies, meta = fetch_proxy_candidates_from_sources
  Rails.logger.info "[FetchProxies] Parsed #{proxies.uniq { |p| [p[:host], p[:port]] }.size}/#{proxies.size} candidates ..."
  self.model = [proxies, meta]
end

# ❌ in the job — the job shouldn't re-explain what the operation did
def perform
  result = MyOperation.call
  Rails.logger.info "Fetched #{result.model.size} records"  # belongs in operation
end
```

## Colored terminal logging — ApplyMate::Logging

`app/concepts/apply_mate/logging.rb` provides a `log` helper for any job or operation. Include it instead of calling `Rails.logger` directly.

```ruby
class MyJob::FetchThings < ApplicationJob
  include ApplyMate::Logging
  # ...
  log("testing #{url}")                              # yellow  info  — tag auto = "FetchThings"
  log("valid #{url} (#{n}/#{target})", color: :green)  # green   info
  log("failed", level: :warn, color: :red)           # red     warn
  log("done in #{t}s", level: :debug)                # yellow  debug
end
```

Available colors: `:yellow` (default), `:green`, `:red`, `:cyan`.  
The `[Tag]` prefix is the **full class name** (`self.class.name`) — e.g. `[Proxy::Operation::ValidateCandidates]`.  
**Do not inline `YELLOW`/`GREEN` constants or define a local `log` method** — always `include ApplyMate::Logging`.

## Job as pure orchestrator — split complex jobs into operations

When a job has multiple distinct phases (fetch → validate → persist), each phase becomes its own operation. The job only calls them in sequence.

```ruby
# ✅ job is 4 lines — each step is testable and renameable independently
class Proxy::Job::FetchProxies < ApplicationJob
  def perform
    candidates = Proxy::Operation::FetchCandidates.call.model
    valid      = Proxy::Operation::ValidateCandidates.call(candidates: candidates).model
    Proxy::Operation::PersistProxies.call(proxies: valid)
  end
end
```

Operations called from jobs (not controllers) receive keyword params directly and skip authorization:

```ruby
class Proxy::Operation::ValidateCandidates < ApplyMate::Operation::Base
  include ApplyMate::Logging

  def perform!(candidates:, **)   # params passed via .call(candidates: ...)
    # no authorize! needed — called from a job, not a controller
    self.model = validate(candidates)
  end
end
```

## Solid Queue — scheduling recurring jobs

Add entries to `config/recurring.yml`:

```yaml
fetch_proxies:
  class: Proxy::Job::FetchProxies
  schedule: every day at 1am

sync_vacancies:
  class: Vacancy::Job::SyncVacancies
  schedule: every day at 5am

clear_finished_jobs:
  command: "SolidQueue::Job.clear_finished_in_batches(sleep_between_batches: 0.3)"
  schedule: every hour at minute 12
```

Format: `every <N> <unit>`, `every day at <time>`, `every hour at minute <N>`.
