# ViewComponents

Components live in `app/concepts/apply_mate/component/` and inherit from `ApplyMate::Component::Base < ViewComponent::Base`.

Templates use Slim (`.html.slim`).

---

## Multi-line `render` calls in Slim

Slim does **not** support multi-line Ruby expressions without explicit line continuation. There are two valid patterns:

### Option A — trailing backslash on every line except the last

```slim
= render ApplyMate::Component::Chat::ConversationList.new( \
    proposals:, \
    print_order_id:, \
    back_url: helpers.chat_print_orders_path \
  )
```

### Option B — closing paren on the last argument line (no backslash needed on that line)

```slim
= render ApplyMate::Component::Chat::ConversationList.new( \
    proposals:, \
    print_order_id:, \
    back_url: helpers.chat_print_orders_path)
```

### Wrong — no backslash, paren on its own line

```slim
/ ❌ This will raise a Slim parse error
= render ApplyMate::Component::Chat::ConversationList.new(
    proposals:,
    print_order_id:,
    back_url: helpers.chat_print_orders_path
  )
```

The same rule applies to any multi-line Ruby call in Slim: `helpers.turbo_frame_tag`, `link_to`, `form_with`, etc.

---

## HTML attributes on tags — use `[]` block, never `\`

Backslash continuation is **not** allowed for HTML attributes on a tag. Use the `[]` block syntax instead:

```slim
/ ✅ Correct — attributes in a [] block
a.flex.items-center.gap-1.text-sm.underline [
  href=helpers.rails_blob_path(attachment, disposition: :attachment)
  class=attachment_link_classes
]
  = content

/ ❌ Wrong — backslash continuation on tag attributes
a.flex.items-center.gap-1.text-sm.underline \
  href=helpers.rails_blob_path(attachment) \
  class=attachment_link_classes
```

The `[]` block also applies to `data-` attributes and dynamic class values:

```slim
.w-10.h-10.rounded-xl [
  class=(locked? ? 'bg-zinc-100 text-zinc-400' : 'bg-indigo-100 text-indigo-600')
  data-controller="example"
]
```

Note: backslash continuation **is** valid for Ruby method calls (`= render ...`, `= helpers.link_to ...`), just not for tag attribute lines.

---

## Passing keyword arguments

The endpoint decomposes `ApplyMate::Operation::Struct` via `.to_h` and passes all keys as keyword args to `initialize`. For plain AR models the key is derived from the component class name (see `ApplyMate::Base::ConceptNaming#find_model_name`).

Components in the `ApplyMate::Component::` namespace must always use `ApplyMate::Operation::Struct` when they need multiple keyword args, because `find_model_name` would otherwise derive an incorrect key (e.g. `apply_mates` instead of the intended model name).

---

## Slots (`renders_one` / `renders_many`)

Use ViewComponent slots for composable sub-sections:

```ruby
renders_one :header
renders_one :messages
renders_one :input
```

Call in templates with:

```slim
= render ApplyMate::Component::Chat::Window.new do |w|
  - w.with_header do
    = render ApplyMate::Component::Chat::Header.new(name: 'Alice')
  - w.with_messages do
    ...
```
