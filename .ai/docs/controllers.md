# Controllers

Controllers use ONLY the `endpoint` method for action implementations.

By default we try to use turbo requests and modals when possible.

## Signature

```ruby
endpoint(operation, component = nil, &block)
```

- `operation` — the Trailblazer operation class to call
- `component` — optional ViewComponent class for rendering
- `block` — optional custom matcher block; custom handlers take **priority** over defaults for the same case (success/invalid), unspecified cases fall back to defaults

## How custom blocks work

The evaluator runs the custom block first, then the default block. `Dry::Matcher::Evaluator` only sets `@output` for the **first** matching handler per case, so a custom `m.success` prevents the default `m.success` from executing. Unhandled cases still fall through to defaults.

## Default Behavior Reference

### HTML format (`ApplyMate::Endpoint::Html`)

| Action    | Result    | Component provided?      | Default behavior |
|-----------|-----------|--------------------------|------------------|
| `create`  | `success` | **ignored** (no component) | Sets flash from `result.notice` if present. Redirects to `controller_name_path` (index). |
| `create`  | `success` | yes                      | Renders the component with `result[:model]` as keyword args. |
| `create`  | `invalid` | ignored                  | Auto-resolves component: `{ControllerPath}::Component::New`. Renders it with `result[:model]`. |
| `update`  | `success` | **ignored** (no component) | Sets flash from `result.notice` if present. Redirects to `edit_controller_name_singular_path(result.model)`. |
| `update`  | `success` | yes                      | Renders the component with `result[:model]` as keyword args. |
| `update`  | `invalid` | ignored                  | Auto-resolves component: `{ControllerPath}::Component::Edit`. Renders it with `result[:model]`. |
| `index`   | `success` | **required**             | Renders the component. `find_model_name` pluralizes the name (e.g., `products:`). |
| `index`   | `invalid` | ignored                  | Auto-resolves component: `{ControllerPath}::Component::New`. Renders it with `result[:model]`. |
| _other_   | `success` | **required**             | Renders the component with `result[:model]` as keyword args. |
| _other_   | `success` | no                       | **Raises** `"We don't handle #{action_name} for HTML by default, please specify a m.success handler"` |
| _other_   | `invalid` | ignored                  | Auto-resolves component: `{ControllerPath}::Component::New` (or `Edit` for `update`). Renders it with `result[:model]`. |

**Success with component = nil (redirect actions):**
- `create` → `redirect_to controller_name_path` (e.g., `products_path`)
- `update` → `redirect_to edit_controller_name_singular_path(result.model)` (e.g., `edit_product_path(@product)`)
- any other action → raises error

**Success with component provided (render actions):**
- Renders the given component. The `model_name` is pluralized for `index` (e.g., `products:`), singular for all others (e.g., `product:`).

**Invalid (all actions):**
- The component class is auto-resolved: `"#{controller_path.singularize.camelize}::Component::#{class_name}"` where `class_name` is `Edit` for `update`, `New` for everything else.
- If the class doesn't exist, raises an error prompting you to define it or handle `m.invalid` manually.
- Renders the resolved component with `result[:model]`.

**Model passing (both success and invalid):**
- If `result[:model]` is a `ApplyMate::Operation::Struct` → decomposed into keyword args via `.to_h` (e.g., `component.new(product: ..., categories: ...)`)
- Otherwise → passed as a single keyword arg named after the model (e.g., `component.new(product: result[:model])`)

### Turbo Stream format (`ApplyMate::Endpoint::TurboStream`)

| Action    | Result    | Component required? | Default behavior |
|-----------|-----------|---------------------|------------------|
| `create`  | `success` | no                  | Sets flash from `result.notice`. Sends `turbo_stream.action(:refresh, nil, method: 'morph')` (full page morph refresh). |
| `create`  | `invalid` | **yes**             | Re-renders component with errors into the existing turbo frame (morph replace). Returns **422**. |
| `update`  | `success` | no                  | Sets flash from `result.notice`. Sends `turbo_stream.action(:refresh, nil, method: 'morph')` (full page morph refresh). |
| `update`  | `invalid` | **yes**             | Re-renders component with errors into the existing turbo frame (morph replace). Returns **422**. |
| `destroy` | `success` | no                  | Sends `turbo_stream.remove_by_id(result.model.id)` + flash via turbo stream. |
| `destroy` | `invalid` | no                  | Sets flash alert with merged errors. Sends flash via turbo stream. Returns **422**. |
| _other_   | `success` | **yes**             | Renders component to HTML string. If component is a modal (class name contains `Modal`): creates a turbo frame element in `#turbo-modals` if it doesn't exist. Replaces the turbo frame content via morph. |
| _other_   | `invalid` | **yes**             | Same as above — re-renders component with validation errors into the turbo frame via morph. Returns **422**. |

**Modal detection:**
- A component is considered a modal if its demodulized class name contains `"Modal"` (e.g., `Product::Component::EditModal`).
- Modal frame ID: `"#{dom_id(model)}_modal"` (e.g., `product_42_modal`).
- The frame is auto-created inside `#turbo-modals` container if it doesn't exist yet.

**Turbo frame ID resolution (non-create/update/destroy):**
- For `Struct` models: `"#{dom_id(result[:model][model_name])}_modal"`
- For regular models: `"#{dom_id(result.model)}_modal"`

## Usage Examples

### Simple — component rendered on success
```ruby
class HomeController < ApplicationController
  def index
    endpoint Home::Operation::Index, Home::Component::Index
  end
end
```

### Create/Update — no component, default redirect
```ruby
class ProductsController < ApplicationController
  def create
    # success → redirects to products_path
    # invalid → renders Product::Component::New
    endpoint Product::Operation::Create
  end

  def update
    # success → redirects to edit_product_path(result.model)
    # invalid → renders Product::Component::Edit
    endpoint Product::Operation::Update
  end
end
```

### Custom handler — overrides both cases
```ruby
class SessionsController < ApplicationController
  def oauth_callback
    params[:auth] = request.env['omniauth.auth']

    endpoint Session::Operation::OauthCallback do |m|
      m.success do |result|
        session[:user_id] = result.model.id
        redirect_to root_path, notice: I18n.t('session.oauth_callback.success')
      end

      m.invalid do
        redirect_to root_path, alert: I18n.t('session.oauth_callback.failure')
      end
    end
  end
end
```

### Custom handler — overrides only success, invalid falls back to default
```ruby
class ProductsController < ApplicationController
  def create
    endpoint Product::Operation::Create do |m|
      m.success do |result|
        redirect_to product_path(result.model), notice: 'Created!'
      end
      # invalid: falls back to default → renders Product::Component::New
    end
  end
end
```
