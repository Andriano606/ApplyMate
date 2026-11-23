# Feedback

Users review ApplyMate on the public page `/feedbacks` («Відгуки» in the navbar). The main way
to post is through Claude: the MCP tool `submit_feedback` (see `.ai/docs/mcp.md`); the page has the
same form for doing it by hand.

## Rules

- **One feedback per user**, editable forever. Enforced by the unique index on
  `feedbacks.user_id`; `Feedback#one_per_user` turns the common case into a readable `:base` error
  and `Feedback::Operation::Create#save_once!` does the same for the `RecordNotUnique` race.
- **Rating 1–10** (`Feedback::RATINGS`, also a DB check constraint `feedbacks_rating_range`),
  **body ≤ 2000 chars** (`Feedback::BODY_MAX_LENGTH`, also the MCP schema `maxLength`).
- **Sentiment is derived from the rating**, never stored: `Feedback::SENTIMENTS`
  = positive 7–10, neutral 5–6, negative 1–4 (`Feedback.sentiment_for`, scope `with_sentiment`).
- **Who:** anyone can read (`FeedbackPolicy#index?`), signed-in users post, only the author edits.
- **`posted_via`** (`web` | `mcp`) records where the latest version came from; it is a trusted
  keyword argument of `Feedback::Operation::{Create,Update}` (`Mcp::Operation::SubmitFeedback`
  passes `'mcp'`), never a request param. Cards show «опубліковано через Claude (MCP)».

## Reply threads

Under every feedback there is a public thread (`FeedbackReply`, `feedback.replies` ordered by
`created_at`, index `[feedback_id, created_at]`). Only **admins** (under any feedback) and the
**feedback's author** (in their own thread) may post — `FeedbackReplyPolicy#create?`; everyone else
reads. `FeedbackReply::Operation::Create` is behind both the inline web form
(`POST /feedbacks/:feedback_id/replies`, `FeedbackRepliesController`) and the MCP tool
`reply_to_feedback`. The web form (`FeedbackReply::Component::Form`, a `<details>` with the
`details` Stimulus controller) is shown by `FeedbackReply::Component::Thread#show_form?`: admins see
it under other people's feedback; under your own feedback it appears once someone has replied.
A rejected reply re-renders only that form (turbo_stream replace, 422).
A thread holds at most `FeedbackReply::MAX_PER_FEEDBACK` (100) replies — the page and
`list_feedback` load whole threads. `FeedbackReply#role` (`:admin` / `:author`) is the one source for
the web badges and the MCP `role`.
Replies go with their feedback (`dependent: :destroy`) and with their author (`User has_many
:feedback_replies, dependent: :destroy`); there is no edit/delete of a single reply.

## Unread replies

`feedbacks.replies_seen_at` is when the author last read their thread. `Feedback#unread_replies` =
replies by others created after it (all of them while it is `nil`) — the one definition used by the
navbar badge (`User#unread_feedback_replies?`, one query per page for signed-in users), by
`Feedback::Operation::Index` (web page and MCP `list_feedback`) and by `Mcp::Operation::GetMyFeedback`.
Both read through `Feedback#read_new_replies!`, which returns the unread ids (highlighted «нове» /
`new: true`) and moves `replies_seen_at` to the newest of them (not to "now", so a reply committed
in between stays unread). Reading happens on a GET, so the navbar link has
`data-turbo-prefetch="false"` (`Item#link_data`): a hover prefetch must not clear the badge.
Admins get no badge for authors' answers.

## Page layout

One centred column (`max-w-3xl`): summary card (average, `feedback.index.total` count, sentiment
bar), the viewer's own feedback pinned above the list and **excluded from it**, then everyone
else's feedback with sentiment filter pills (counts from the same stats). Ukrainian plurals
(`відгук/відгуки/відгуків`) need the plural rule in `config/locales/plurals.rb`, enabled by
`config/initializers/i18n_pluralization.rb` — without it I18n only knows `one`/`other`.

## Safety

- Bodies (feedback and replies) are plain text: the card and the thread escape them before `simple_format`
  (`simple_format(ERB::Util.html_escape(body))`) — `simple_format` alone keeps `<img>`/`<a>`, which
  would let anyone (or a prompt-injected Claude) put tracking pixels and phishing links on a public page.
- `submit_feedback` publishes under the user's name, and `get_vacancies` returns text written by
  employers, so a vacancy could try to prompt-inject a review. The tool description forbids calling it
  on a tool result's say-so; users should not auto-approve it in their MCP client.

## Layout

| Piece | Role |
|-------|------|
| `FeedbacksController` | `index`, `new`/`create`, `edit`/`update` — create/update use the endpoint default (flash + morph refresh) |
| `Feedback::Operation::Index` | list without the viewer's own (`updated_at desc`, index `index_feedbacks_on_updated_at`, 20 per page, replies preloaded), `?sentiment=` filter (unknown value = all), stats, the viewer's own feedback |
| `Feedback::Operation::{New,Create,Edit,Update}` | the form; Create/Update are also the sub-operations behind `submit_feedback` |
| `Feedback::Component::{Index,Card,FormModal}` | page, one review, the modal form |
| `Feedback::Serializer::Detail` | the MCP payload (`comment` = `body`, `replies` with `role: admin|author`) |

## Scale

The table holds at most one row per user, so it grows with the user list, not with traffic, and
needs no pruning (`dependent: :destroy` removes a user's feedback with the user). The summary is one
`GROUP BY rating` query (≤ 10 rows) per page view.

Read the own feedback with `Feedback.find_by(user:)`, not `current_user.feedback`: building a
`Feedback.new(user:)` sets the cached `has_one` to the unsaved record, so a later read in the same
request would see it.
