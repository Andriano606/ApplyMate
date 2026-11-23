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

## Safety

- The body is plain text: the card escapes it before `simple_format`
  (`simple_format(ERB::Util.html_escape(body))`) — `simple_format` alone keeps `<img>`/`<a>`, which
  would let anyone (or a prompt-injected Claude) put tracking pixels and phishing links on a public page.
- `submit_feedback` publishes under the user's name, and `get_vacancies` returns text written by
  employers, so a vacancy could try to prompt-inject a review. The tool description forbids calling it
  on a tool result's say-so; users should not auto-approve it in their MCP client.

## Layout

| Piece | Role |
|-------|------|
| `FeedbacksController` | `index`, `new`/`create`, `edit`/`update` — create/update use the endpoint default (flash + morph refresh) |
| `Feedback::Operation::Index` | list (`updated_at desc`, index `index_feedbacks_on_updated_at`, 20 per page), `?sentiment=` filter (unknown value = all), stats, the viewer's own feedback |
| `Feedback::Operation::{New,Create,Edit,Update}` | the form; Create/Update are also the sub-operations behind `submit_feedback` |
| `Feedback::Component::{Index,Card,FormModal}` | page, one review, the modal form |
| `Feedback::Serializer::Detail` | the MCP payload (`comment` = `body`) |

## Scale

The table holds at most one row per user, so it grows with the user list, not with traffic, and
needs no pruning (`dependent: :destroy` removes a user's feedback with the user). The summary is one
`GROUP BY rating` query (≤ 10 rows) per page view.

Read the own feedback with `Feedback.find_by(user:)`, not `current_user.feedback`: building a
`Feedback.new(user:)` sets the cached `has_one` to the unsaved record, so a later read in the same
request would see it.
