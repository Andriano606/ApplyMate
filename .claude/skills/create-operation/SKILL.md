---
name: create-operation
description: Instructions for creating a Create/Update operation. Use when adding a create or update action to a resource.
---

# Create a Create/Update Operation

A create operation lives at `app/concepts/<resource>/operation/create.rb` and inherits from `ApplyMate::Operation::Base`. All logic goes in `perform!`.

## Structure

```ruby
# frozen_string_literal: true

class <Resource>::Operation::Create < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    self.model = current_user.<resources>.build
    authorize! model, :create?

    form_object = <Resource>::FormObject::Create.new(params[:<resource>])
    parse_validate_sync(form_object, model)
    model.save!
    notice(I18n.t('<resource>.create.success'))
  end
end
```

## Step 1 — Build the model

Assign `self.model` before doing anything else. The base class copies errors to it and exposes it via the result:

```ruby
self.model = current_user.<resources>.build
```

## Step 2 — Authorize with Pundit

Always call `authorize!` before any destructive work. It delegates to `<Resource>Policy#create?`:

```ruby
authorize! model, :create?
```

## Step 3 — Form object

Form objects serve as a whitelist and validation layer between raw params and the model. They restrict which attributes can be set and let you express validations that only apply to a specific operation (e.g., requiring a password confirmation on sign-up but not on profile edit) — keeping the model free of context-specific rules. **Creating the form object is covered by a separate skill.**

```ruby
form_object = <Resource>::FormObject::Create.new(params[:<resource>])
parse_validate_sync(form_object, model)
```

`parse_validate_sync` runs form validations, syncs the form data to the model, then re-runs model validations. If any step fails it adds errors to the result and raises `ActiveRecord::RecordInvalid`, which the base `call` method catches.

## Step 4 — Save and notify

```ruby
model.save!
notice(I18n.t('<resource>.create.success'))
```

## Raising non-ActiveRecord errors

When the operation should fail for a business reason that isn't a model validation (e.g. an expired token, an external API rejection, a business rule violation), add the error manually then raise `ActiveRecord::RecordInvalid`:

```ruby
add_error :base, I18n.t('<resource>.errors.something')
raise ActiveRecord::RecordInvalid
```

The base `call` method rescues `ActiveRecord::RecordInvalid` and copies all accumulated errors to the result, so the controller/component sees a failed operation with a human-readable message.

## Locales

Add all keys used in the operation to `config/locales/uk.yml`:

```yaml
<resource>:
  create:
    success: Успішно створено
  errors:
    something: Опис помилки
```

## Checklist

- [ ] `app/concepts/<resource>/operation/create.rb`
- [ ] `app/policies/<resource>_policy.rb` — `create?` method present
- [ ] `app/concepts/<resource>/form_object/create.rb` — covered by separate skill
- [ ] `config/locales/uk.yml` — success notice + any custom error keys added
