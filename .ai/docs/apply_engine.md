# Apply Engine

How an `Apply` runs: lifecycle states, why a run stops (`Halt` codes), the submit claim, `run_token` fencing, the
heartbeat and the Runner. Read before touching `Apply` state, `Apply::Operation::Engine::*` or `Apply::Job::*`.
Handler/step authoring is in `apply_handlers.md`.

## Operations, not POROs

Every piece of procedural engine logic is an internal operation (`ApplyMate::Operation::Base` subclass: calls
`skip_authorize`, sets `self.model`, invoked as `Klass.call(...).model`). Only exceptions and two value types
(`Context`, `Lifecycle::Decide::Decision`) are plain classes.

| File (`app/concepts/apply/operation/engine/`) | What it is |
|---|---|
| `halt.rb` | `Halt < StandardError`: the code → kind → state tables |
| `fenced.rb`, `not_startable.rb` | `Fenced`, `NotStartable` (`StandardError`) |
| `context.rb` | `Context = Data.define(:apply, :attempt, :run_token, :deadline_at, :fence_flag)`, no DB writes |
| `start_context.rb` | `StartContext`: takes the row for one run, returns the `Context` |
| `fenced_update.rb` | `FencedUpdate`: the only fenced write to `applies` |
| `heartbeat.rb`, `heartbeat/tick.rb` | `Heartbeat` (starts the `Concurrent::TimerTask`), `Heartbeat::Tick` (one beat) |
| `lifecycle/base.rb` | shared `transition!` / `broadcast` helpers |
| `lifecycle/decide.rb` | `Decide`: the ONLY claim rule + auto-resume-once + failure hash; returns `Decide::Decision` |
| `lifecycle/record_halt.rb` | `RecordHalt`: writes `Decide`'s decision for the owning run (fenced) |
| `lifecycle/finish.rb` | `Finish`: `completed`, `submitted_via: 'engine'` |
| `lifecycle/halt_unowned.rb` | `HaltUnowned`: halt for a row no run owns (queued / waiting_capacity only) |
| `claim_submit.rb` | `ClaimSubmit`: the submit claim |
| `close_steps.rb` | `CloseSteps`: fails `apply_steps` rows a lost / fenced run left `running` |
| `redact.rb` | `Redact`: the single redactor |
| `enqueue.rb` | `Enqueue`: `Apply::Job::Apply.perform_later` + `applies.job_id` |
| `broadcast.rb` | `Broadcast`: `StatusUpdate.broadcast(apply.reload)`, failures reported and swallowed |
| `run.rb` | `Run`: the Runner |
| `reap_stale.rb`, `expire_waiting.rb`, `prune_apply_steps.rb` | recurring sweeps (see below); jobs in `app/concepts/apply/job/` only call them |

`Apply::Handler::Base#call` → `Apply::Operation::Engine::Run.call(apply:, handler: self)`.

## Lifecycle states

`Apply#state` (`app/models/apply.rb`). The integers are used literally by the partial indexes and by
`StartContext`'s SQL; `spec/models/apply_indexes_spec.rb` keeps the indexes in sync with the lists.

| State | Int | Lists |
|---|---|---|
| `queued` | 0 | ACTIVE, IN_PROGRESS |
| `running` | 1 | ACTIVE, IN_PROGRESS |
| `waiting_capacity` | 2 | ACTIVE, IN_PROGRESS |
| `needs_review` | 3 | ACTIVE, ATTENTION, WAITING |
| `needs_human` | 4 | ACTIVE, ATTENTION, RESUMABLE, WAITING |
| `completed` | 5 | |
| `failed` | 6 | ATTENTION, RESUMABLE |
| `unsupported` | 7 | ATTENTION, RESUMABLE |
| `submit_unverified` | 8 | ATTENTION |
| `cancelled` | 9 | |

- `ACTIVE_STATES` → `index_applies_one_active_per_vacancy` (one active apply per user + vacancy).
- `ATTENTION_STATES` → inbox filter and navbar counter (`Apply.attention_count_for`, cache key
  `users.applies_changed_at.iso8601(6)` — microseconds, so two transitions in one second get two keys — touched
  AFTER every state change: `FencedUpdate`, `HaltUnowned`, `ReapStale`, `ExpireWaiting`, the user operations, and
  `Destroy` after the delete).
- `RESUMABLE_STATES` + `!claimed?` + no submitted sibling (`Apply.submitted_sibling_of`) → `Apply#resumable?`.
- `WAITING_STATES` → `ExpireWaiting` (48 h reminder, then expiry; `Apply::WAIT_TIMEOUTS`).
- While `running`, `applies.stage` holds the running step's stage (cleared by every lifecycle transition).

### Exit table (design §11.1)

| State | Entered by | Exit |
|---|---|---|
| queued / running | Create, Resume, auto-resume, Approve, ProvideInput | steps finish; reaper |
| waiting_capacity | `PoolBusy`, `Throttled` (phases 2 / 3a) | job retry; after exhaustion `failed(:capacity)` → Resume |
| needs_review | ReviewGate, FillFields, `already_applied` (phase 3a) | Approve, Edit, Cancel; `failed(:review_expired)` after `Apply::REVIEW_TIMEOUT` |
| needs_human | `needs_human` halts before the claim (incl. `manual_apply_required`) | "Fixed, retry" (Resume), "I applied manually" (MarkOutcome → `completed`, `submitted_via: manual`), "Open link", Cancel; reminder after `Apply::REMIND_AFTER`, `failed(:human_timeout)` after `Apply::HUMAN_TIMEOUT` |
| failed | transient / permanent halts before the claim | Resume (attempt + 1) unless a sibling apply already claimed / submitted; `ai_lifetime_cap`: only Cancel or "apply again" |
| unsupported | unsupported halts before the claim | Resume, "Open link", "I applied manually", Cancel |
| submit_unverified | any halt after the claim, `already_claimed`, `outcome_unknown` | "It was sent" → `completed`; "It was not sent" → MarkOutcome releases the claim → `failed` |
| completed / cancelled | — | "Apply again" creates a new Apply only with `confirm_reapply` |

## Halt

`Apply::Operation::Engine::Halt.new(code, detail: nil, definitive: false)`: unknown codes raise `ArgumentError`.
`CODES` is the single code → kind map, `KIND_STATE` the single kind → state map. Later phases add producers, not
parallel tables. The i18n spec iterates `CODES`: every code needs `apply.failure.<code>` and
`apply.failure_hint.<code>` in uk and en, and users only ever see those texts (`failure.detail` is admin-only).

| Kind | State | Codes |
|---|---|---|
| transient | failed | `worker_lost deadline browser_crashed capacity` |
| permanent | failed | `budget_exhausted ai_budget_exhausted ai_lifetime_cap stuck invalid_ai_output required_field_unfillable no_widget_driver target_not_found target_obstructed validation_rejected invalid_record unexpected_error review_expired human_timeout legacy_failure` |
| unsupported | unsupported | `login_required closed_posting bot_wall not_a_form no_application_path external_messenger private_address wizard_too_long` |
| needs_human | needs_human | `captcha_challenge email_code missing_profile_fact session_expired ai_integration_cannot_navigate manual_apply_required` |
| unverified | submit_unverified | `already_claimed outcome_unknown` |
| review | needs_review | `review already_applied` |

- `manual_apply_required` is the "apply yourself" outcome (design §18): Google Forms, visible captcha, other
  targets the engine will not submit. Detail is a symbol such as `:google_forms` / `:captcha`.
- `legacy_failure` exists only for rows backfilled from the pre-engine `failed_*` statuses.
- `CLAIM_RELEASING = %i[session_expired validation_rejected]`: `Halt#releases_claim?` is true only for these codes
  raised with `definitive: true` (deterministic proof that nothing was accepted).

`applies.failure` (jsonb) is built only by `Lifecycle::Decide`, for every writer:
`{ code, kind, stage, detail (redacted), after_claim, attempt, auto_resumed? }` plus the writer's extras
(`ExpireWaiting`: `expired_at`, `previous`). `stage` is the running step's stage for `RecordHalt` / `ReapStale`,
nil for `HaltUnowned` / `ExpireWaiting`.

### Exception mapping in the Runner

| Raised by a step | Code |
|---|---|
| `Halt` | its own code |
| `ApplyMate::Ai::Client::Base::EmptyResponse`, `ApplyMate::Ai::ResponseSchema::Json::InvalidResponse` | `invalid_ai_output` |
| `ActiveRecord::RecordInvalid` outside an operation, or a step result with `failure?` | `invalid_record` (detail = error messages) |
| any other `StandardError` | `unexpected_error` (detail = `"Class: message"`, redacted; also `Rails.error.report`) |

## Claim rule

`ClaimSubmit.call(ctx:)` is called by the submit step right before the irreversible POST / click:

```sql
UPDATE applies SET submit_claimed_at = now(), updated_at = now()
 WHERE id = $1 AND run_token = $2 AND submit_claimed_at IS NULL AND submitted_at IS NULL
```

- 0 rows (already claimed or submitted) or `ActiveRecord::RecordNotUnique` on
  `index_applies_one_open_claim_per_vacancy` (another non-cancelled apply of the same user + vacancy holds an open
  claim) → `Halt(:already_claimed)`. The UPDATE runs in a savepoint so the violation never aborts an outer
  transaction.
- `Lifecycle::Decide.call(apply:, halt:, stage: nil, auto_resume: true, extra: {}).model` →
  `Decision(state, auto_resume, release_claim, failure)` is the single implementation, used by `RecordHalt`,
  `ReapStale`, `HaltUnowned` (`auto_resume: false`) and `ExpireWaiting`:
  `claimed = apply.claimed?`; `release = claimed && halt.releases_claim?`;
  `auto_resume = auto_resume && halt.kind == :transient && !claimed && !failure.auto_resumed`;
  `state = auto_resume ? :queued : (claimed && !release ? :submit_unverified : halt.state)`.
  `Decision#attributes` (`state`, `failure`, `stage: nil`, `submit_claimed_at: nil` on release) is what each writer
  puts in its one UPDATE. The code is kept in `failure.code` for display.
- A claimed apply is never auto-resumed and never `resumable?`; only MarkOutcome resolves it.

## Fencing

- Every engine write to `applies` goes through `FencedUpdate.call(ctx:, attributes:, extra_condition: nil)`:
  `Apply.where(id:, run_token:)` (+ the trusted SQL fragment) `.update_all(attributes + updated_at)`. Rides the
  primary key.
- 0 rows and the run no longer owns the row → `ctx.fence!` and `Fenced`. 0 rows only because `extra_condition`
  failed (row still owned) → model `0`, no raise; the caller decides (ClaimSubmit → `already_claimed`, Tick →
  fence itself).
- `ctx.check_fence!` (in-memory `Concurrent::AtomicBoolean`, set by the heartbeat thread) runs before every step and
  every `FencedUpdate`.
- On `Fenced` (or `NotStartable`) the Runner logs and returns: no state, failure, step row or broadcast is written.
- `apply_steps` rows are not fenced: a row carries its run's `attempt`, and no other run writes that attempt's rows.
  A fenced or dead run leaves its last step row `running`; whoever takes the row over closes it with `CloseSteps`
  (`failed`, `error_code`, `finished_at`): `ReapStale` (the reaped attempt, code `worker_lost` / `deadline`),
  `StartContext` (every earlier attempt, `worker_lost`) and `RecordHalt` (its own attempt). So no step row spins
  forever and every row eventually gets a `finished_at` for `PruneApplySteps`.

## StartContext and timing

```sql
UPDATE applies
   SET state = 1, attempt = attempt + 1, run_token = gen_random_uuid(),
       deadline_at = now() + RUN_DEADLINE, heartbeat_at = now(), stage = NULL, updated_at = now()
 WHERE id = $1
   AND (state IN (0, 2) OR (state = 1 AND COALESCE(heartbeat_at, updated_at) < now() - STALE_AFTER))
RETURNING attempt, run_token, deadline_at
```

0 rows → `NotStartable`: a second job never starts on top of a live run; a job redelivered after a crash starts
once the old heartbeat is stale. After a start, `CloseSteps` fails step rows of earlier attempts still `running`. `failure` is kept across starts (it carries `auto_resumed`). `ai_calls = 0` joins
this statement in phase 3a.

| Constant (`Apply::`) | Value | Used by |
|---|---|---|
| `RUN_DEADLINE` | 30 min | `StartContext` (`deadline_at`); the Runner raises `Halt(:deadline)` before a step once `ctx.remaining <= 0` |
| `STALE_AFTER` | 3 min | `StartContext` takeover of a `running` row; `ReapStale` candidates |
| `HEARTBEAT_GRACE` | 5 min | `Heartbeat::Tick` stops beating after `deadline_at + HEARTBEAT_GRACE` |
| `REAPER_GRACE` | 15 min | `ReapStale`: a live process is trusted until `deadline_at + REAPER_GRACE` |
| `HUMAN_TIMEOUT` | 7 days | `ExpireWaiting` (`WAIT_TIMEOUTS['needs_human']`), `Apply#wait_expires_at` |
| `REVIEW_TIMEOUT` | 72 h | `ExpireWaiting` (`WAIT_TIMEOUTS['needs_review']`), `Apply#wait_expires_at` |
| `REMIND_AFTER` | 48 h | `ExpireWaiting` reminder (`REMINDER_DUE_SQL`, `index_applies_remind_candidates`) |

`Apply::Job::Apply` runs on queue `apply` with `limits_concurrency to: 1, key: "apply:<id>", duration: 45.minutes`:
longer than `RUN_DEADLINE + HEARTBEAT_GRACE` (35 min), after which a run cannot own its row anyway. Ownership for
the whole run is enforced by `run_token` + heartbeat, not by the concurrency window.

## Heartbeat

- `Heartbeat.call(ctx:).model` is a running `Concurrent::TimerTask` (`INTERVAL = 30` s, `run_now: false`); the
  Runner calls `shutdown` in `ensure`.
- Each tick: `Rails.application.executor.wrap` + `connection_pool.with_connection` → `Heartbeat::Tick`, i.e.
  `FencedUpdate(heartbeat_at: now)` with `extra_condition: now() < deadline_at + HEARTBEAT_GRACE`. 0 rows (token
  rotated, or past the grace) → `ctx.fence!`, model `false`; Tick never raises out of the timer. Other tick errors
  (DB down, pool timeout) are reported by the executor wrap to `Rails.error`.
- **DB pool sizing.** Each apply-worker thread holds one primary connection for its run plus one for its ticker:
  the apply worker's primary pool must be `>= 2 * APPLY_SLOTS + 2` (8 for `APPLY_SLOTS = 3`).
  `Apply::Operation::AssertQueueTopology` fails the boot below that for `SQ_ROLE=apply` (`required_primary_pool`,
  `primary_pool_size` from `config/database.yml`). The `database.yml` default `max_connections` is
  `RAILS_MAX_THREADS || 8`; staging's primary is pinned to 8; dev uses `APP_DB_POOL` (25).

## Runner

`Apply::Operation::Engine::Run.call(apply:, handler:)`:

1. `StartContext` (`NotStartable` → log `runner skipped`, return).
2. `Heartbeat` ticker.
3. For each `handler.class.steps` in order:
   - `step.condition && !step.condition.call(ctx)` → skip (no row);
   - `ctx.check_fence!`; `ctx.remaining <= 0` → `Halt(:deadline)`;
   - `FencedUpdate(stage: step.operation.stage)`, `ApplyStep.create!(attempt: ctx.attempt, key: step.key,
     stage:, position: step.position, state: :running, started_at:)`, `Broadcast`;
   - `step.operation.call(ctx:, handler:, **step.options)`; `result.failure?` → `Halt(:invalid_record)`;
   - step row `succeeded` + `finished_at`; on an exception (not `Fenced`) the row becomes `failed` with
     `error_code` and redacted `error_detail`, and the exception continues up.
4. `Lifecycle::Finish`, or `Lifecycle::RecordHalt` for a `Halt` / mapped exception (`Decide`, one fenced UPDATE,
   `CloseSteps` for this attempt, broadcast, `Enqueue` on auto-resume).
5. `ensure`: ticker shutdown.

Phase 1 runs every applicable step on every attempt; input digests, skip-with-restore and atomic session scopes
come in phase 3a. Logs carry `apply=<hashid> step=<key> attempt=<n>` (Runner) and
`apply=<hashid> attempt=<n> halt=<code>` (RecordHalt).

**Auto-resume** (decided by `Lifecycle::Decide`). A transient halt before the claim, when `failure.auto_resumed` is not yet set, records `queued`
(instead of `failed`) with `failure.auto_resumed = true`, broadcasts, then `Enqueue`s a new job (blocked by
`limits_concurrency` until the current job finishes). Every later halt carries the flag, so this happens once per
Apply; the next transient halt stays `failed` for the user to Resume. If `Enqueue` raises, the job's rescue marks
the queued row `failed(:unexpected_error)` through `HaltUnowned`.

**Job.** `Apply::Job::Apply#perform` finds the apply (missing → `nil`), resolves the handler and calls it. Any
`StandardError` that reaches the job (handler resolution, recording failures) → `HaltUnowned(:unexpected_error,
detail: class name)` and re-raise. `HaltUnowned` writes only `queued` / `waiting_capacity` rows, so a live run is
never touched; it writes `Decide`'s decision with `auto_resume: false` (the job itself failed; re-enqueueing from
here could loop).

**Broadcasts.** The Runner broadcasts each stage, Lifecycle each transition, through `Engine::Broadcast`. The state
is already committed when it runs, so a render failure is reported (`Rails.error`, handled) and swallowed.

### Legacy steps in phase 1

The Runner wraps the pre-engine steps unchanged in their HTTP / AI behaviour; only the state plumbing moved
(details and the submit tables in `apply_handlers.md`).

| Stage key | Steps | Halt codes they raise |
|---|---|---|
| `check_applyable` | `CheckApplyable` | `no_application_path` |
| `fetch_apply_type` | `FetchApplyType` | `no_application_path` |
| `fetch_details` | `FetchDetails` (Djinni) | — |
| `fetch_form` | `FetchInternalForm`, `Ai::FetchExternalForm` | `not_a_form`, `no_application_path`, `target_not_found` |
| `fill_form` | `Ai::FillForm` | `invalid_ai_output` |
| `generate_cv` | `Ai::GeneratePdfCv` | — (`Apply.with_cv_or_generating_cv` keys on this string) |
| `submit` | `SendApply::Http`, `SendApply::Browser` | `outcome_unknown` (Http), `session_expired` (definitive), `validation_rejected` (not definitive), `target_not_found`; Browser's unusable verdict leaks `EmptyResponse` / `InvalidResponse` → `invalid_ai_output` |

- Steps raise through `Apply::Operation::Base#halt!(code, detail:, definitive:)`.
- Claim placement: `SendApply::Http` claims after building the payload, right before `post_multipart`;
  `SendApply::Browser` claims after `attempt_recaptcha_refresh` and the `clickable?` check of the submit button,
  right before the submit click. A missing trigger / submit button halts before the claim (`failed`).
- Only `SendApply::Http`'s login redirect is definitive (releases the claim → `needs_human`). The browser verdict
  (`CheckSubmitResult`, now strict) never is: `success: false` (`validation_rejected`) and an empty / unparseable
  verdict (not rescued in the step; `Run::ERROR_CODES` → `invalid_ai_output`) keep the claim (`submit_unverified`).
  There is one exception → code table, `Run::ERROR_CODES`; steps do not keep their own.

## Recurring jobs (general queue)

All three run on queue `default` (never launch a browser), are scheduled in `config/recurring.yml` and are thin
`ApplicationJob`s around an operation, each with `limits_concurrency to: 1` and an explicit `duration:`.

| Job | Schedule | `limits_concurrency` key / duration | Operation |
|---|---|---|---|
| `Apply::Job::ReapStale` | every minute | `apply_reap_stale` / 10 min | `Engine::ReapStale` |
| `Apply::Job::ExpireWaiting` | every hour at minute 7 | `apply_expire_waiting` / 30 min | `Engine::ExpireWaiting` |
| `Apply::Job::PruneApplySteps` | every day at 4am | `apply_prune_apply_steps` / 1 h | `Engine::PruneApplySteps` |

`ReapStale#perform` rescues `StandardError` (log + `Rails.error.report`): the job must not raise, the next minute
retries.

### Reaper

`Engine::ReapStale.call(batch_size: 100, max_batches: 10)` -> `{ reaped:, resumed:, alive: }`.
Candidates: state in `IN_PROGRESS_STATES` with `COALESCE(heartbeat_at, updated_at) < STALE_AFTER.ago`, oldest
first (`index_applies_stale_candidates`). The job behind a candidate is looked up by `applies.job_id` =
`SolidQueue::Job.active_job_id`.

| Job state | Verdict |
|---|---|
| no `job_id`, no job, finished, `failed_execution` | lost |
| ready / scheduled / blocked execution (queued behind busy slots or `limits_concurrency`) | alive |
| claimed by a process with `last_heartbeat_at` < 5 min old, `deadline_at` nil or `now < deadline_at + REAPER_GRACE` | alive |
| claimed but the process stopped heartbeating, or past `deadline_at + REAPER_GRACE` | lost |

A lost run is closed by ONE `UPDATE ... WHERE id AND run_token = <old> AND state IN (0, 1, 2)` that also writes a
**new `run_token`** (rotation fences the zombie: its next `FencedUpdate` raises `Fenced`). A run that finished
(`Finish` / `RecordHalt` keep `run_token`, but leave the in-progress states) or restarted (`StartContext` rotates
the token) between the candidate SELECT and the UPDATE makes it a no-op. The outcome is `Lifecycle::Decide`'s:

| Row | Result |
|---|---|
| claimed (`submit_claimed_at`) | `submit_unverified`, never auto-resumed |
| not claimed, `failure.auto_resumed` not set | `queued` + `failure.auto_resumed = true`, then `Enqueue` (resume **once**) |
| not claimed, already auto-resumed | `failed` |

`failure.code` is `deadline` when `deadline_at` is past, else `worker_lost` (both transient). After a successful
UPDATE, `CloseSteps` fails the reaped attempt's step rows still `running` with that code. Each decision touches
`users.applies_changed_at` and broadcasts. A row that raises is reported and skipped; the sweep continues.

Termination: an empty or short batch, or `max_batches`. Alive (and raising) rows stay stale-looking, so their ids
are excluded from the next batch (at most `batch_size * max_batches` ids) instead of being re-read forever and
without hiding lost rows behind them.

### ExpireWaiting

`Engine::ExpireWaiting.call(batch_size: 100)` -> `{ human_timeout:, review_expired:, reminded: }`. "Waiting
since" is `updated_at` (every transition bumps it; the reminder write does not).

1. Expire: `needs_human` older than `HUMAN_TIMEOUT` -> `human_timeout`; `needs_review` older than
   `REVIEW_TIMEOUT` -> `review_expired` (no producer before phase 3a; `index_applies_waiting_updated`). The state
   comes from `Lifecycle::Decide` (`failed`, or `submit_unverified` for a claimed row); the old failure is kept in
   `failure.previous`, `failure.expired_at` is set. The UPDATE matches `state`, so a user action in between wins.
2. Remind: `WAITING_STATES` rows with `updated_at < REMIND_AFTER.ago` and `REMINDER_DUE_SQL`
   (`reminded_at IS NULL OR reminded_at < updated_at`, the predicate of `index_applies_remind_candidates`) get
   `reminded_at = now` (UPDATE matches `id`, `state` and the read `updated_at`), a counter-key touch and a broadcast.
   A row that re-enters a waiting state is due again without any reset (its `updated_at` moved past `reminded_at`).
   Channel: in-app only (no mailer is configured): `Apply#reminded?` makes `FailureNotice` show
   `apply.failure_notice.reminder` with `Apply#wait_expires_at`; the navbar counter already counts the row.

At most `batch_size` rows per expiry state and `batch_size` reminders per run; the hourly schedule drains a
backlog. A row that raises is reported and skipped.

### Pruning

`Engine::PruneApplySteps` deletes `apply_steps` with `finished_at < RETENTION` (180 days,
`index_apply_steps_on_finished_at`; a row a lost run left `running` gets its `finished_at` from `CloseSteps`), `BATCH_SIZE = 1000` per DELETE, at most
`MAX_BATCHES = 50` per run. `applies` are never auto-deleted; destroying an apply removes its steps
(`dependent: :destroy`).

## Redactor

`Apply::Operation::Engine::Redact.call(text:, apply: nil).model` — the only redactor (failure.detail, step
error_detail, later traces/artifacts). Nil-safe, symbols are stringified, output truncated to `MAX_LENGTH = 2_000`.

| Category | Result |
|---|---|
| `Cookie:` / `Set-Cookie:` / `Authorization:` lines | line dropped |
| `csrfmiddlewaretoken= csrftoken= sessionid= token= code=` values (also `access_token=`) | `name=[REDACTED]` |
| the apply's `source_profile.session_id`, `user.email` (>= 6 chars) | `{{fact.session_id}}`, `{{fact.email}}` |
| any other email | `{{email}}` |
| phone-like digit runs (`\+?\d[\d\s().-]{8,}\d`) | `{{phone}}` (also hits long ids / dates, on purpose) |

## User operations

The user acts on an apply through four operations (`Apply::Operation::Resume`, `Cancel`, `MarkOutcome`, and `Destroy`). All load the record with `policy_scope(Apply).find`, so another user's apply is a 404, then authorize with `resume?`/`cancel?`/`mark_outcome?` (owner only). Each transition is one state-guarded `UPDATE` (`update_all ... WHERE id AND state IN (...)`): 0 rows means a concurrent run, claim or cancel won, and the user gets the `not_allowed` error. After a transition they `touch_user_applies_changed_at!` (navbar counter key), broadcast through `Engine::Broadcast`, and answer with a notice. The controller renders only a flash turbo stream; the cards refresh through the broadcast.

| Operation | Allowed from | Writes | Refused when |
|---|---|---|---|
| Resume | `failed`, `unsupported`, `needs_human` with `submit_claimed_at` NULL and no submitted sibling (`Apply#resumable?`) | `queued`, `stage` NULL, then `Engine::Enqueue` | `submit_unverified`, claimed `needs_human`, another apply for the vacancy already active (`already_active`), another non-cancelled apply for the vacancy already claimed or submitted (`already_submitted`) |
| Cancel | `Apply::CANCELLABLE_STATES`: `queued`, `needs_human`, `failed`, `unsupported`, `needs_review` | `cancelled`, `run_token` rotated, `stage` NULL | `running` (wait for finish or the reaper), `submit_unverified` (resolve through MarkOutcome) |
| MarkOutcome `sent` | `submit_unverified` | `completed`, `submitted_at` now, `submitted_via` `engine` | any other state |
| MarkOutcome `not_sent` (needs `confirm=1`) | `submit_unverified` | `failed`, `submit_claimed_at` NULL (frees `index_applies_one_open_claim_per_vacancy`), `failure.resolved = not_sent` | missing confirmation, any other state |
| MarkOutcome `manual` ("I applied manually") | `needs_human`, `unsupported`, `failed`, `submit_unverified` | `completed`, `submitted_at` now, `submitted_via` `manual`; an existing claim stays | `running`, `queued`, ... |

Resume keeps `failure` (the timeline shows it as the previous attempt; the next halt or finish overwrites it).
Resume is the one way back into a submit that `Create`'s `confirm_reapply` does not cover, so it refuses outright
when `Apply.submitted_sibling_of(apply)` (`reapply_guarded` minus the apply itself) exists: in `Apply#resumable?`
(the Actions button is hidden) and again as `NOT EXISTS` inside the state-guarded UPDATE. `ClaimSubmit`'s open-claim
index would not catch it once the sibling is `submitted_at`. The user can still "apply again" through Create. Cancel rotates `run_token` so a job that starts late hits `NotStartable` (StartContext refuses state `cancelled`). `MarkOutcome::OUTCOMES` is the single table that drives the three outcomes.

## Create guards

`Apply::Operation::Create` checks, after `parse_validate_sync`:

1. Daily limit: `current_user.applies.where(created_at: today).count >= users.daily_apply_limit` (default 30) gives `apply.create.daily_limit_reached` (rides `index_applies_on_user_created`).
2. Re-apply: `Apply.reapply_guarded` (a prior apply that claimed or submitted, not cancelled) needs `confirm_reapply=1` (a virtual form property), else `reapply_confirmation_required`.
3. A second active apply for the vacancy is rejected by the real partial unique index `index_applies_one_active_per_vacancy`: `RecordNotUnique` becomes `already_active`.

On success it calls `Engine::Enqueue` (stores `job_id`) and touches the user's counter key.

## Attention inbox

`GET /applies?filter=attention` returns `Apply.attention` rows (`ATTENTION_STATES`), riding `index_applies_on_user_state`. `Apply::Operation::Index` exposes `ApplyMate::Operation::Struct(applies:, filter:, attention_count:)`; the count is `Apply.attention_count_for(user)`, cached under a key that changes with `users.applies_changed_at`. Unknown filter values are ignored.

## Artifacts

Stored files (Apply `cv`/`screenshot`, VacancyCv `cv`) are never linked through permanent blob URLs. `GET /artifacts/:owner/:id/:name` (`artifact_path(owner:, id: hashid, name:, disposition:)`, owner `apply|vacancy_cv`, name `cv|screenshot`) runs `Artifact::Operation::Show`, which resolves the record through `policy_scope`, authorizes `show?`, checks the name against the owner table (`OWNERS`) and answers a 5-minute presigned storage URL (`inline`, or `attachment` for `disposition=attachment`). `ArtifactsController` redirects to it with `allow_other_host: true` (minio is another host). Unknown owner/name or a missing attachment is a 404. The design names this `Apply::Operation::ShowArtifact` / `ApplyArtifactsController`; one generic operation was chosen so `VacancyCv` (rendered by the same `CvContent` component) needs no second copy.

## UI

State is the single source for the UI: `StatusPill`/`StatusBadge` map `Apply.states` to `apply.state.<state>` and the
current stage to `apply.stage.<stage>`; `ActionBox` offers Apply / Retry (Resume) / Cancel by state;
`FailureNotice` shows only localized `apply.failure.<code>` and `apply.failure_hint.<code>` (never raw
exceptions); for `needs_human`/`unsupported` it shows the "apply yourself" notice with "Відкрити посилання" and
"Я подався вручну" (MarkOutcome `manual`). `RunTimeline` renders the preloaded `apply_steps` grouped by attempt
(newest open). The navbar counter and the "Потребують уваги" filter share `Apply.attention_count_for`.
`spec/i18n/apply_engine_keys_spec.rb` iterates `Halt::CODES`, `Apply.states` and every `Apply::Operation::Base`
stage, so a new code/state/stage without uk and en texts fails the suite (and en must contain no Cyrillic).

## Deviations from the design (phase 1)

- Column subset: only the columns phase 1 needs exist (`state`, `stage`, `attempt`, `run_token`, `heartbeat_at`,
  `deadline_at`, `submit_claimed_at`, `submitted_via`, `failure`, `job_id`, ...); later phases add the rest.
- `Artifact::Operation::Show` is generic (Apply and VacancyCv) instead of `Apply::Operation::ShowArtifact`.
- The 48 h reminder is in-app only (card notice + navbar counter); no e-mail/push channel exists yet.
- Legacy data writes (`inputs`, `filled_inputs`, `cv`, `apply_type`, ...) by the legacy steps are not fenced until
  phase 4; only lifecycle writes go through `FencedUpdate`.
- No browser/AI artifacts are stored yet, `RunTimeline` shows step rows only.

## Specs

- `engine_context(apply)` (`spec/support/apply_engine.rb`) is a real `StartContext`; `rotate_run_token!(apply)`
  simulates a newer run (zombie).
- `spec/support/apply_engine_fakes.rb`: `ApplyEngineFakes::PrepareStep` (`stage :fake_prepare`),
  `ApplyEngineFakes::SubmitStep` (`stage :fake_submit`) and `ApplyEngineFakes::Handler`. Stub the step's
  `observe(ctx, **options)` to look at the run mid-step or to raise / claim.
- Engine specs live in `spec/concepts/apply/operation/engine/`. Stub `Apply::TurboHandler::StatusUpdate.broadcast`;
  use `type: :job` where `have_enqueued_job` is asserted (auto-resume, Enqueue).
- `spec/concepts/apply/job/apply_e2e_spec.rb` runs Job -> Handler -> Runner on the honeytech DOU context (claim,
  step rows, idempotent re-run, zombie writes nothing, `job_id` stored by `Enqueue`).
