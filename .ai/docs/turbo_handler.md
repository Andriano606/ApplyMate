# TurboHandler — real-time broadcasts

TurboHandlers live in `app/concepts/<resource>/turbo_handler/`. They push real-time UI updates to subscribed clients via ActionCable without a user request. Only the base class (`ApplyMate::TurboHandler::Base`) exists today — no concrete handler is in the codebase right now. The examples below use a generic `Widget` resource; they are illustrative, not real classes.

All handlers inherit `ApplyMate::TurboHandler::Base` and implement three class methods:

| Method | Purpose |
|--------|---------|
| `stream_from(record, view_context)` | Sets up the ActionCable subscription in the template |
| `frame_tag(record, view_context, &block)` | Wraps content in a `<turbo-frame>` identified by `frame_id` |
| `broadcast(record)` | Renders the component and pushes it to subscribers |

## User-scoped broadcasts

When a badge/status belongs to a specific user (not shared across all viewers of a record), scope both the subscription channel and the frame ID to `[user, record]`.

```ruby
class Widget::TurboHandler::StatusUpdate < ApplyMate::TurboHandler::Base
  def self.stream_from(widget, user, view_context)
    view_context.turbo_stream_from([ user, widget ])
  end

  def self.frame_tag(widget, user, view_context, &block)
    view_context.turbo_frame_tag(frame_id(widget, user), &block)
  end

  def self.broadcast(status)
    html = ApplicationController.renderer.render_to_string(
      Widget::Component::StatusBadge.new(widget: status.widget, user: status.user),
      layout: false,
    )
    Turbo::StreamsChannel.broadcast_action_to(
      [ status.user, status.widget ], action: :replace, target: frame_id(status.widget, status.user), html:
    )
  end
end
```

In the template, pass `current_user` to `stream_from`; the component resolves its own user:

```slim
= Widget::TurboHandler::StatusUpdate.stream_from(@widget, current_user, helpers)
= render Widget::Component::StatusBadge.new(widget: @widget)
```

And inside the component template that wraps itself in the frame:

```slim
= Widget::TurboHandler::StatusUpdate.frame_tag(@widget, @user, helpers) do
  ...
```

`current_user` is nil when the component is rendered via `ApplicationController.renderer` in `broadcast`, so user-scoped components take a `user:` kwarg (default sentinel resolved in `before_render`, see `view_component.md`). Broadcasts always pass `user:` explicitly — it must also work when there is no record to derive it from (e.g. the last record was just destroyed).

## One stream, several frames

When several handlers update different parts of the same page for the same `[user, record]`, the page subscribes **once** (one handler's `stream_from`; the others delegate to it and must not be called a second time on the same page). A broadcast whose frame is not on the page is simply ignored.

**Live updates are as narrow as the change.** A broadcast that replaces a whole list re-renders native `<details>` (accordions) closed and tabs on their default tab, so the user's open accordions/selected tabs on *other* items reset. Replace only the item that changed; replace the whole list only when items are added or removed. Never insert a row relative to a sibling that might not be rendered yet — Turbo would drop the action and the list would never recover.

## Index broadcasts reuse the index operation

A lazy-frame index broadcast renders exactly what its controller action renders by calling the same operation with the broadcast user, then spreading the struct into the component:

```ruby
result = Widget::Operation::Index.call(params: { widget_id: widget.id }, current_user: user)
ApplicationController.renderer.render_to_string(Widget::Component::Index.new(**result.model.to_h, user:), layout: false)
```

Never rebuild the operation's query inside the handler — two copies drift.

## Callers pass the full record, not its parent

Pass the full record so the handler can access `record.user`:

```ruby
# ✅ correct
Widget::TurboHandler::StatusUpdate.broadcast(status)

# ❌ wrong — loses the user
Widget::TurboHandler::StatusUpdate.broadcast(status.widget)
```

## `ApplicationController.renderer` has no request context

`current_user` returns `nil` inside `render_to_string`. Pass all user-specific data directly to the component constructor. See `view_component.md` for the sentinel pattern.
