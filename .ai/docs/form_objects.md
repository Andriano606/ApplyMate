# Form Objects

Form objects handle input parsing, validation, and syncing to models. Located at `app/concepts/<model_name>/form_object/<action>.rb`.

## Defining Properties

```ruby
class Proposal::FormObject::Edit < ApplyMate::FormObject::Base
  property :title                              # synced to model via sync_to
  property :step, virtual: true               # NOT synced (virtual)
  property :selected, default_value: false    # synced, default applied if nil
  property :photo, attachment: true           # file upload, skipped by assign_properties_from_model
end
```

## Subforms

```ruby
has_many :proposal_materials, form: ProposalMaterial::FormObject::Base
has_one  :address, form: Address::FormObject::Base
```

`valid?` on the parent also validates all subforms. `sync_to(parent_model)` cascades into each subform via `sync_subform`.

## Initialization Order

Understanding this order is essential for overriding setters:

1. `assign_properties_from_model` — reads model attributes into ivars (skips ActiveStorage attachments)
2. `assign_subforms_from_model` — wraps associated records as subform instances into `@subform_name`
3. `assign_properties(params)` — calls `property_name=` for each param key present

This means: overriding a property setter can safely access `@proposal_materials` (already initialized in step 2):

```ruby
def selected_proposal_material_ids=(value)
  @selected_proposal_material_ids = value
  return if value.blank?

  hashids = value.values.flat_map { |v| v.split(',') }
  @proposal_materials = @proposal_materials.map do |pm|
    pm.selected = hashids.include?(pm.hashid)
    pm
  end
end
```

## sync_to

`sync_to(model)` syncs all dirty (ivar-set) non-virtual properties to the model, then cascades into subforms. Only properties with set ivars (`dirty_properties`) are synced — properties loaded from model but unchanged are still considered dirty.

For the cascade to **persist** subform changes, the AR association must have `autosave: true`:

```ruby
# app/models/proposal.rb
has_many :proposal_materials, dependent: :destroy, autosave: true
```

Without `autosave: true`, `parent.save!` will NOT save modifications to existing associated records made via `sync_to`.

## Attachment Validation Pitfall

`assign_properties_from_model` **skips** ActiveStorage attachments — `@photo` remains nil even when `model.photo.attached?`. This causes `validates :photo, presence: true` to fail when loading existing records as subforms.

Fix:
```ruby
validates :photo, presence: true, unless: :photo_persisted?

private

def photo_persisted?
  model&.photo&.attached?
end
```

## has_many Subform Validation Cascade

When using `has_many :foo, form: Bar`, `form.valid?` validates every `Bar` subform. If `Bar` has validations appropriate only for creation (e.g. photo presence), they will fail when loading existing records in an edit context. Use `unless:` guards as shown above.

## Multi-Step Forms

Steps accumulate data in hidden HTML fields — all previous step data is re-submitted with each subsequent step. `all_steps_done` validation fails until the final step, keeping the result `invalid` so the endpoint re-renders the form with the advanced step:

```ruby
validate :all_steps_done

def all_steps_done
  return if step_1_satisfied? && step_2_satisfied? && submitted_step == 'last_step'
  errors.add(:step, 'not all steps done')
end
```

The `validate_form_object` helper raises `ActiveRecord::RecordInvalid` on failure, which is caught by `call`'s rescue — **code after `validate_form_object` never runs on failure**.

## Params Key

`simple_form_for form_object` derives the params key from the class name:
- `Proposal::FormObject::Edit` → `params[:proposal_form_object_edit]`
- `Proposal::FormObject::Base` → `params[:proposal_form_object_base]`

If some fields use manual `name:` HTML attributes with a different prefix (e.g. `proposal[field]`), params are split across keys. Merge them in the operation:

```ruby
form_params = (params[:proposal_form_object_edit] || {}).merge(params[:proposal] || {})
form = Proposal::FormObject::Edit.new(form_params, proposal)
```
