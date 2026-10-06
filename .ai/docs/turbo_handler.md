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
    view_context.turbo_stream_from([ user, vacancy ])
  end

  def self.frame_tag(vacancy, user, view_context, &block)
    view_context.turbo_frame_tag(frame_id(vacancy, user), &block)
  end

  # One apply changed (pipeline step): badge, action box and only that apply's card.
  def self.broadcast(apply)
    latest = broadcast_summary(apply.vacancy, apply.user)
    Apply::TurboHandler::VacancyIndex.broadcast_card(apply, open: apply == latest)
  end

  # The set of applies changed (create / destroy): badge, action box and the whole panel.
  def self.refresh(vacancy, user)
    broadcast_summary(vacancy, user)
    Apply::TurboHandler::VacancyIndex.broadcast(vacancy, user)
  end

  def self.broadcast_summary(vacancy, user)
    apply = Apply.latest_for(vacancy:, user:)
    html = ApplicationController.renderer.render_to_string(
      Apply::Component::StatusBadge.new(vacancy:, apply:, user:),
      layout: false,
    )
    Turbo::StreamsChannel.broadcast_action_to([ user, vacancy ], action: :replace, target: frame_id(vacancy, user), html:)
    Apply::TurboHandler::ActionBox.broadcast(vacancy, user, apply)
    apply
  end
end
```

In the template, pass `current_user` to `stream_from`; the component resolves its own user:

```slim
= Apply::TurboHandler::StatusUpdate.stream_from(@vacancy, current_user, helpers)
= render Apply::Component::StatusBadge.new(vacancy: @vacancy)
```

And inside the component template that wraps itself in the frame:

```slim
= Apply::TurboHandler::StatusUpdate.frame_tag(@vacancy, @user, helpers) do
  ...
```

`current_user` is nil when the component is rendered via `ApplicationController.renderer` in `broadcast`, so user-scoped components take a `user:` kwarg defaulting to `LAZY` and resolve it in `before_render` (see `view_component.md`). Broadcasts always pass `user:` explicitly — it must also work when there is no record to derive it from (e.g. the last apply was just destroyed).

## One stream, several frames: the vacancy page

Every per-user apply view of a vacancy rides the single `[user, vacancy]` stream. The vacancy page subscribes **once** (`Apply::TurboHandler::StatusUpdate.stream_from`); the other handlers' `stream_from` delegate to it and must not be called a second time on the same page. The vacancy page renders the action box and the applies panel, not the status badge — `Apply::Component::StatusBadge` lives on vacancy cards (`Vacancy::Component::Card`) and in the "My applies" table (`Apply::Component::Table`), which subscribe to the same stream; a broadcast whose frame is not on the page is simply ignored.

| Handler | Frame id | Component | Broadcast |
|---|---|---|---|
| `Apply::TurboHandler::StatusUpdate` | `apply_status_<vacancy>_<user>` | `Apply::Component::StatusBadge` | `broadcast(apply)` / `refresh(vacancy, user)` — the single entry point, fans out to the two below |
| `Apply::TurboHandler::ActionBox` | `apply_action_box_<vacancy>_<user>` | `Apply::Component::ActionBox` | `broadcast(vacancy, user, apply)` — only called by `StatusUpdate` |
| `Apply::TurboHandler::VacancyIndex` | `vacancy_applies_<vacancy>_<user>` (lazy, `src: vacancy_applies_path`); cards `apply_<hashid>` | `Apply::Component::VacancyIndex` / `Apply::Component::VacancyApplyCard` | `broadcast(vacancy, user)` (whole panel) / `broadcast_card(apply, open:)` (one card) — only called by `StatusUpdate` |

`Apply::Operation::Base` calls `StatusUpdate.broadcast(apply)` on every pipeline step — it replaces only that apply's card. `Apply::Operation::Create` and `Apply::Operation::Destroy` call `refresh(vacancy, user)`, which re-renders the whole panel because its membership changed.

**Live updates are as narrow as the change.** A broadcast that replaces a whole list re-renders native `<details>` (accordions) closed and tabs on their default tab, so the user's open accordions/selected tabs on *other* items reset. Replace only the item that changed; replace the whole list only when items are added or removed.

The CV list (`VacancyCv::TurboHandler::Index`, stream `[user, vacancy, :vacancy_cvs]`) is separate: `broadcast(vacancy, user)` (whole list) is called by `VacancyCvsController#create`, `Apply::Operation::Destroy` and `Apply::Operation::Ai::GeneratePdfCv` on start (its placeholder row appears); `broadcast_row(record)` (replaces that row's own `cv_<record>` frame in place, or removes it; whole list only when the last row is gone and the empty state swaps in) is called by `GeneratePdfCv` in `cleanup`, after the final status is stored. Rows are never inserted relative to a sibling: if that sibling were not rendered yet (two applies starting at once), Turbo would drop the action and the list would never recover.

The questions list (`VacancyQuestion::TurboHandler::Index`, stream `[user, vacancy, :vacancy_questions]`): `broadcast(vacancy, user)` is called by `VacancyQuestionsController#create`, by `Apply::Operation::FetchInternalForm` / `Apply::Operation::Ai::FetchExternalForm` (a new form brings new question suggestions) and by `Apply::Operation::Destroy`.

## Index broadcasts reuse the index operation

A lazy-frame index broadcast renders exactly what its controller action renders by calling the same operation with the broadcast user, then spreading the struct into the component:

```ruby
result = VacancyCv::Operation::Index.call(params: { vacancy_id: vacancy.id }, current_user: user)
ApplicationController.renderer.render_to_string(VacancyCv::Component::Index.new(**result.model.to_h, user:), layout: false)
```

Never rebuild the operation's query inside the handler — two copies drift (`VacancyCv::TurboHandler::Index`, `VacancyQuestion::TurboHandler::Index`, `Apply::TurboHandler::VacancyIndex` all follow this).

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
