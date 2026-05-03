---
name: turbo-handler
description: Instructions for creating/updating a TurboHandler for async frontend updates via ActionCable. Use when adding real-time UI updates pushed from background jobs or operations (e.g. status badges, progress indicators, any component that updates without a user action).
---

# Async Frontend Updates via TurboHandler

A TurboHandler encapsulates three concerns in one place: subscribing the client to a stream, wrapping a component in a stable turbo frame, and broadcasting server-side renders back to that frame. Use `ApplyMate::TurboHandler::Base` as the base class.

## Pattern overview

```
ApplyMate::TurboHandler::Base      ← abstract base (do not modify)
  └── <Resource>::TurboHandler::<Name>   ← one class per update type
```

Three class methods must be implemented:

| Method | Called from | Purpose |
|---|---|---|
| `stream_from(record, view_context)` | view template | subscribe client to ActionCable stream keyed on `record` |
| `frame_tag(record, view_context, &block)` | component template | wrap rendered content in a `<turbo-frame>` with a stable id |
| `broadcast(record)` | operation / job | push a fresh render of the component to the frame |

---

## 1. Create the TurboHandler class

`app/concepts/<resource>/turbo_handler/<name>.rb`

```ruby
# frozen_string_literal: true

class <Resource>::TurboHandler::<Name> < ApplyMate::TurboHandler::Base
  def self.stream_from(record, view_context)
    view_context.turbo_stream_from(record)
  end

  def self.frame_tag(record, view_context, &block)
    view_context.turbo_frame_tag(frame_id(record), &block)
  end

  def self.broadcast(record)
    Turbo::StreamsChannel.broadcast_action_to(
      record,
      action: :replace,
      target: frame_id(record),
      html: ApplicationController.render(<Resource>::Component::<ComponentName>.new(<resource>: record), layout: false)
    )
  end

  private

  def self.frame_id(record)
    "<resource>_<name>_#{record.hashid}"
  end
end
```

Rules:
- `frame_id` must be unique per record — use `record.hashid`, never `record.id`.
- The `broadcast` method renders the **same component** that `frame_tag` wraps. Keep them in sync.
- `broadcast_action_to` uses `:replace` so the frame content is swapped in-place; the frame element itself is preserved.

---

## 2. Component template — wrap content in frame_tag

Inside the component's `.html.slim` that will be live-updated:

```slim
= <Resource>::TurboHandler::<Name>.frame_tag(@<resource>, helpers) do
  / ... component markup ...
```

The entire component body (or just the dynamic part) goes inside the block. On broadcast, this block is what gets replaced.

---

## 3. Containing view — subscribe to the stream

`stream_from` emits a `<turbo-stream-source>` tag (invisible) that opens the WebSocket subscription. It must appear **somewhere on the same page** as the `frame_tag` — the DOM position does not matter.

### Show page

Call `stream_from` once, immediately before or near the component:

```slim
= <Resource>::TurboHandler::<Name>.stream_from(@<resource>, helpers)
= render <Resource>::Component::<ComponentName>.new(<resource>: @<resource>)
```

### Table / index page (one subscription per row)

When the live component appears inside a table column, emit `stream_from` inside the same cell using `helpers.safe_join`. The invisible `<turbo-stream-source>` element is valid anywhere in the DOM, including inside a `<td>`:

```ruby
table.add_column(header: '...') do |record|
  helpers.safe_join([
    <Resource>::TurboHandler::<Name>.stream_from(record, helpers),
    render(<Resource>::Component::<ComponentName>.new(<resource>: record))
  ])
end
```

`stream_from` and `frame_tag` are separate because the subscription can live anywhere on the page while the frame lives inside the component itself.

---

## 4. Broadcast from an operation or background job

Call `broadcast` after mutating the record. A private helper keeps operations clean:

```ruby
def update_status(new_status)
  model.update!(status: new_status)
  broadcast
end

def broadcast
  <Resource>::TurboHandler::<Name>.broadcast(model)
end
```

Call `broadcast` every time the state the component displays changes — including error states.

---

## Real example: Apply::TurboHandler::StatusUpdate

- Handler: `app/concepts/apply/turbo_handler/status_update.rb`
- Component using `frame_tag`: `app/concepts/apply/component/status_badge.html.slim`
- `stream_from` callers:
  - Show page: `app/concepts/apply/component/show.html.slim` (before the status row)
  - Index table status column: `app/concepts/apply/component/table.rb` (via `safe_join` inside `add_column`)
  - Vacancy card: `app/concepts/vacancy/component/card.slim` (line 26)
- Broadcast callers: `Apply::Operation::Ai::GeneratePdfCv` — called on every status transition (`generating_cv`, `cv_generated`, `failed_cv_generation`)

---

## Checklist

- [ ] `app/concepts/<resource>/turbo_handler/<name>.rb` created, all three methods implemented
- [ ] Component template wraps dynamic content in `frame_tag`
- [ ] Parent template calls `stream_from` before rendering the component
- [ ] Every status/state mutation in operations/jobs calls `broadcast`
- [ ] `frame_id` uses `hashid`, not `id`
- [ ] `broadcast` renders the same component class that `frame_tag` wraps
