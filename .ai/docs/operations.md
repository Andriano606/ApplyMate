# Operations

All operations inherit from `ApplyMate::Operation::Base` and are located at `app/concepts/<model_name>/operation/<action>.rb`.

## Creating an Operation

Operations implement a public `perform!(**attrs)` method (not `call`). The base class handles:
- Instantiation and calling via `self.call(**args)`
- Creating `ApplyMate::Operation::Result` automatically
- Rescuing `ActiveRecord::RecordInvalid` and copying errors
- Copying result errors to model errors

```ruby
class Home::Operation::Index < ApplyMate::Operation::Base
  def perform!(params:, current_user:)
    skip_authorize
    # Business logic here
  end
end
```

## Authorization

Authorization must be called in every operation:

- `authorize!(record, query)` — checks Pundit policy, sets `result[:pundit] = true`
- `authorize_and_save!(auth_method = nil)` — authorizes and saves the model
- `policy_scope(scope)` — applies Pundit policy scope, sets `result[:pundit_scope] = true`
- `skip_authorize` — marks authorization as skipped (for public actions)
- `skip_policy_scope` — marks policy scope as skipped

### Index Operations (Fetching Collections)

For index operations that fetch collections, always use `policy_scope` instead of `Model.all`. This ensures proper authorization and filtering based on user permissions. Combine with `authorize!` to check if the user can access the index action:

```ruby
class Admin::Material::Operation::Index < ApplyMate::Operation::Base
  def perform!(params:, current_user:)
    authorize! Material, :index?
    self.model = policy_scope(Material).order(:name)
  end
end
```

The policy scope is defined in the policy class:

```ruby
class MaterialPolicy < ApplicationPolicy
  def index?
    user&.admin?
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      scope.all if user&.admin?
    end
  end
end
```

## Helpers

- `self.model = record` / `self.model` — get/set the model on the result (`result[:model]`)
- `self.redirect_path = path` — set redirect path on the result
- `notice(text, level: :notice)` — set a flash-like notice on the result
- `add_error(key, message)` — add an error to the result
- `run_operation(operation_class, parameters)` — run a sub-operation

## Result (`ApplyMate::Operation::Result`)

Located at `app/concepts/apply_mate/operation/result.rb`. All operations return this.

- `result.success?` / `result.failure?` — check outcome
- `result.model` — the main record (set via `self.model =` in operation)
- `result[:key]` / `result[:key] = val` — hash-like access for arbitrary data
- `result.errors` — ActiveModel errors
- `result.redirect_path` — redirect path if set
- `result.message` / `result.message_level` — notice text and level
- `result.sub_results` — results from sub-operations
- `result.invalid!` — force the result to be a failure

## Passing Multiple Parameters to Components

When you need to pass multiple values to a component, use `ApplyMate::Operation::Struct` instead of setting multiple `result[:key]` values. This keeps the data organized and passes cleanly to the component via `self.model`.

```ruby
class Admin::Printer::Operation::New < ApplyMate::Operation::Base
  def perform!(params:, current_user:)
    self.model = ApplyMate::Operation::Struct.new(
      printer: Printer.new,
      materials: policy_scope(Material).order(:name)
    )
    authorize! model.printer, :new?
  end
end
```

Then in the component:

```ruby
class Admin::Printer::Component::New < ApplyMate::Component::Base
  def initialize(printer:, materials:, **)
    @printer = printer
    @materials = materials
  end
end
```

The `endpoint` method automatically expands struct attributes as keyword arguments to the component initializer.

## Multi-Step Form Operations

Multi-step forms keep the result `invalid` after each intermediate step so the endpoint re-renders with the advanced step. Data from previous steps is preserved in hidden HTML fields and re-submitted with every step.

```ruby
class Proposal::Operation::Update < ApplyMate::Operation::Base
  def perform!(params:, current_user:)
    # Merge params from form object key AND manual field overrides
    form_params = (params[:proposal_form_object_edit] || {}).merge(params[:proposal] || {})
    form = Proposal::FormObject::Edit.new(form_params, proposal)
    form.submitted_step = form.step
    self.model = form

    # Advance step before validation — the form re-renders showing the next step
    form.step = 'delivery' if form.step == 'materials' && form.one_selection_satisfied?

    # validate_form_object raises ActiveRecord::RecordInvalid on failure.
    # Code below NEVER runs on intermediate steps (all_steps_done fails).
    validate_form_object(form)

    ApplicationRecord.transaction do
      form.sync_to(proposal)
      proposal.save!
    end
  end
end
```

Key points:
- `validate_form_object` raises on failure → the `rescue` in `call` catches it → `sync_to`/`save!` never run on intermediate steps
- The `all_steps_done` validation keeps the form invalid until all steps are complete
- Only the final submit actually persists data

## "Save as default" User Preferences Pattern

When a form collects data that should optionally update user defaults, handle it in the operation after the transaction:

```ruby
ApplicationRecord.transaction do
  form.sync_to(proposal)
  proposal.save!
end

if form.save_nova_poshta_as_default.to_s == '1'
  current_user.update!(
    default_nova_poshta_city_ref:      form.customer_nova_poshta_city_ref,
    default_nova_poshta_warehouse_ref: form.customer_nova_poshta_warehouse_ref
  )
end
```

Show the checkbox only when the values are filled AND differ from the user's current defaults (see `form.html.slim` for the pattern).
