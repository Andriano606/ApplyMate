# TurboHandler — real-time broadcasts

TurboHandlers live in `app/concepts/<resource>/turbo_handler/`. They push real-time UI updates to subscribed clients via ActionCable without a user request.

All handlers inherit `ApplyMate::TurboHandler::Base` and implement three class methods:

| Method | Purpose |
|--------|---------|
| `stream_from(record, view_context)` | Sets up the ActionCable subscription in the template |
| `frame_tag(record, view_context, &block)` | Wraps content in a `<turbo-frame>` identified by `frame_id` |
| `broadcast(record)` | Renders the component and pushes it to subscribers |

## User-scoped broadcasts

When a badge/status belongs to a specific user (not shared across all viewers of a record), scope both the subscription channel and the frame ID to `[user, record]`.

```ruby
class Apply::TurboHandler::StatusUpdate < ApplyMate::TurboHandler::Base
  def self.stream_from(vacancy, user, view_context)
    view_context.turbo_stream_from([user, vacancy])
  end

  def self.frame_tag(vacancy, user, view_context, &block)
    view_context.turbo_frame_tag(frame_id(vacancy, user), &block)
  end

  def self.broadcast(apply)
    vacancy = apply.vacancy
    user    = apply.user
    html = ApplicationController.renderer.render_to_string(
      Apply::Component::StatusBadge.new(vacancy: vacancy, apply: apply),
      layout: false,
    )
    Turbo::StreamsChannel.broadcast_action_to(
      [user, vacancy],
      action: :replace,
      target: frame_id(vacancy, user),
      html:,
    )
  end

  private

  def self.frame_id(vacancy, user)
    "apply_status_#{vacancy.hashid}_#{user.hashid}"
  end
end
```

In the template, pass `current_user` to both `stream_from` and `frame_tag`:

```slim
= Apply::TurboHandler::StatusUpdate.stream_from(@vacancy, current_user, helpers)
= render Apply::Component::StatusBadge.new(vacancy: @vacancy)
```

And inside the component template that wraps itself in the frame:

```slim
= Apply::TurboHandler::StatusUpdate.frame_tag(@vacancy, frame_user, helpers) do
  ...
```

Use `frame_user` (a helper method on the component) rather than `current_user` directly — because when the component is rendered via `ApplicationController.renderer` in `broadcast`, `current_user` is nil. Derive the user from the record instead:

```ruby
def frame_user
  @apply.nil? ? current_user : @apply.user
end
```

## Operations call `broadcast(apply)`, not `broadcast(apply.vacancy)`

Pass the full record so the handler can access `apply.user`:

```ruby
# ✅ correct
Apply::TurboHandler::StatusUpdate.broadcast(apply)

# ❌ wrong — loses the user
Apply::TurboHandler::StatusUpdate.broadcast(apply.vacancy)
```

## `ApplicationController.renderer` has no request context

`current_user` returns `nil` inside `render_to_string`. Pass all user-specific data directly to the component constructor. See `view_component.md` for the `LAZY` sentinel pattern.
