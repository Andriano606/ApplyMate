# Apply Engine

How an `Apply` runs: lifecycle states, why a run stops (`Halt` codes), the submit claim, `run_token` fencing, the
heartbeat and the Runner. Read before touching `Apply` state, `Apply::Operation::Engine::*` or `Apply::Job::*`.
Handler/step authoring is in `apply_handlers.md`.

## Contents

- [Operations, not POROs](#operations-not-poros) · [Lifecycle states](#lifecycle-states) · [Halt](#halt) ·
  [Claim rule](#claim-rule) · [Fencing](#fencing) · [StartContext and timing](#startcontext-and-timing) ·
  [Heartbeat](#heartbeat)
- [Runner](#runner) (failure artifacts, host slots, legacy steps) ·
  [Recurring jobs](#recurring-jobs-general-queue) (reaper, ExpireWaiting, pruning)
- Phase 3a data: [Apply::Field](#applyfield) (engine columns, profile facts) · [Context scratch](#context-scratch)
- Phase 3a pipeline: [Handler::Dou routing](#handlerdou-routing) · [Stages of phase 3a](#stages-of-phase-3a) ·
  [Platform adapters (DSL)](#platform-adapters-dsl) · [Detection](#detection) · [Gates](#gates) ·
  [DetectPlatform, FetchSchema](#stages-detectplatform-fetchschema) · [Answers and review](#answers-and-review) ·
  [Snapshot and form elements](#snapshot-and-form-elements) · [Reach form](#reach-form) ·
  [Field inventory](#field-inventory) · [Widgets](#widgets) · [Obstruction](#obstruction) ·
  [Submit and Verify](#submit-and-verify) · [Як додати нову платформу](#як-додати-нову-платформу) ·
  [Smoke survey](#smoke-survey-read-only)
- [Redactor](#redactor) · [User operations](#user-operations) · [Create guards](#create-guards) ·
  [Attention inbox](#attention-inbox) · [Artifacts](#artifacts) · [UI](#ui)
- Deviations: [phase 1](#deviations-from-the-design-phase-1) · [phase 3a](#deviations-from-the-design-phase-3a) ·
  [Specs](#specs)

## Operations, not POROs

Every piece of procedural engine logic is an internal operation (`ApplyMate::Operation::Base` subclass: calls
`skip_authorize`, sets `self.model`, invoked as `Klass.call(...).model`). Only exceptions and small value types
(`Context` + `Context::Scratch`, `Lifecycle::Decide::Decision`, `Detect::Evidence` / `Detect::Match`) are plain
classes. Declarative plugin classes (platform adapters, gates, widget drivers, recipe ops) live in typed folders
(`apply/platform/`, `apply/gate/`, `apply/widget/`, `apply/recipe/op/`) and delegate real work to operations.

| File (`app/concepts/apply/operation/engine/`) | What it is |
|---|---|
| `halt.rb` | `Halt < StandardError`: the code → kind → state tables |
| `fenced.rb`, `not_startable.rb` | `Fenced`, `NotStartable` (`StandardError`) |
| `context.rb` | `Context = Data.define(:apply, :attempt, :run_token, :deadline_at, :fence_flag, :scratch)`; writes only through `persist!` (FencedUpdate) |
| `detect.rb` | `Detect`: the one platform detector; `Detect::Evidence`, `Detect::Match` value types |
| `collect_http_evidence.rb`, `collect_rendered_evidence.rb` | HTTP-level (guarded redirect walk) and rendered-level (`detect.js` per frame) evidence |
| `run_gates.rb` | `RunGates`: runs the platform's gates for one event |
| `check_apply_key.rb` | `CheckApplyKey`: cross-board duplicate check (`Halt(:already_applied)`) |
| `start_context.rb` | `StartContext`: takes the row for one run, returns the `Context` |
| `fenced_update.rb` | `FencedUpdate`: the only fenced write to `applies` |
| `heartbeat.rb`, `heartbeat/tick.rb` | `Heartbeat` (starts the `Concurrent::TimerTask`), `Heartbeat::Tick` (one beat) |
| `lifecycle/base.rb` | shared `transition!` / `broadcast` helpers |
| `lifecycle/decide.rb` | `Decide`: the ONLY claim rule + auto-resume-once + failure hash; returns `Decide::Decision` |
| `lifecycle/record_halt.rb` | `RecordHalt`: writes `Decide`'s decision for the owning run (fenced) |
| `lifecycle/finish.rb` | `Finish`: `completed`, `submitted_via: 'engine'` |
| `lifecycle/wait_capacity.rb` | `WaitCapacity`: the owning run found no browser slot (`PoolBusy`): `waiting_capacity`, stage nil, steps closed `capacity` |
| `lifecycle/halt_unowned.rb` | `HaltUnowned`: halt for a row no run owns (queued / waiting_capacity only) |
| `claim_submit.rb` | `ClaimSubmit`: the submit claim |
| `close_steps.rb` | `CloseSteps`: fails `apply_steps` rows a lost / fenced run left `running` |
| `redact.rb` | `Redact`: the single redactor |
| `enqueue.rb` | `Enqueue`: `Apply::Job::Apply.perform_later` + `applies.job_id` |
| `broadcast.rb` | `Broadcast`: `StatusUpdate.broadcast(apply.reload)`, failures reported and swallowed |
| `run.rb` | `Run`: the Runner |
| `throttled.rb` | `Throttled(until:)`: the tenant host slot is taken (raised by `Stage::AcquireHostSlot`) |
| `capture_artifact.rb` | `CaptureArtifact`: masked screenshot / redacted HTML of the open session onto a step row |
| `redact_tree.rb` | `RedactTree`: `Redact` over every string leaf of a hash / array (step `result` and `trace`) |
| `reap_stale.rb`, `expire_waiting.rb`, `prune_apply_steps.rb` | recurring sweeps (see below); jobs in `app/concepts/apply/job/` only call them |
| `reach_form.rb`, `wait_ready.rb` | `ReachForm` (canonical unwrap / navigation recipe → ready form root), `WaitReady` (readiness poll over frames) |
| `form_elements.rb` | `FormElements`: the snapshot elements inside `ctx.form_root` (frame + region), minus `excluded_regions` |
| `build_field_inventory.rb`, `reconcile_fields.rb` | `BuildFieldInventory` (snapshot + schema → `[Apply::Field]`), `ReconcileFields` (stored ↔ fresh) |
| `set_field_value.rb`, `guard_action.rb` | `SetFieldValue` (widget write + read-back + one fallback), `GuardAction` (obstruction guard) |
| `collect_submit_evidence.rb`, `verify_submit.rb` | `CollectSubmitEvidence` (`Evidence` value), `VerifySubmit` (`Verdict` value) |

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
| waiting_capacity | `PoolBusy` (phase 2), `Throttled` (3a) | `Run` rescues `PoolBusy` / `Throttled`, `Lifecycle::WaitCapacity` (fenced, `failure` untouched) and re-raises; `Throttled`: `Apply::Job::Apply` `rescue_from` → `retry_job(wait_until: error.until)` while its own counter `exception_executions['throttle_waits']` (`THROTTLE_WAITS_KEY`, serialized with the job; not `executions`, which also counts the PoolBusy retries) stays below `MAX_THROTTLE_WAITS = 12`, then `HaltUnowned(:capacity)`; `PoolBusy`: `Apply::Job::Apply` `retry_on` 8× `polynomially_longer` (7 retries: ≈ 78 min, up to ≈ 90 min with jitter); `StartContext` restarts the row from state 2; `ReapStale` sees the scheduled retry as alive (it reads the **newest** `solid_queue_jobs` row of the `active_job_id`: each retry inserts a new row, the finished ones stay until `clear_finished_in_batches`); after exhaustion `HaltUnowned(:capacity)` → `failed(:capacity)` (no auto-resume) → Resume |
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
| `ApplyMate::Client::Browser::PoolBusy` | `capacity` (the step row; the apply goes to `waiting_capacity`, see exit table) |
| `ApplyMate::Client::Browser::Crashed` | `browser_crashed` (transient) |
| `ApplyMate::Client::Browser::DeadlineExceeded` | `deadline` (transient) |
| `Apply::Operation::Engine::Throttled` | `capacity` (the step row; the apply goes to `waiting_capacity`, like `PoolBusy`) |
| `ApplyMate::Client::Browser::TargetNotFound` | `target_not_found` |
| `ApplyMate::Client::Browser::Obstructed` | `target_obstructed` |
| `ApplyMate::Client::Browser::VersionMismatch` | `unexpected_error` (deliberate: permanent until the deploy is fixed) |
| `ApplyMate::Net::UnsafeUrlError` | `private_address` (unsupported) |
| any other `StandardError` | `unexpected_error` (detail = `"Class: message"`, redacted; also `Rails.error.report`) |

**Browser errors.** `Crashed` is transient: `Decide` auto-resumes once (before the claim), the second one stays
`failed` for the user. `DeadlineExceeded` (a Session ran past its `deadline:`) is the transient `deadline`.
`TargetNotFound` is permanent `target_not_found`. `UnsafeUrlError` is `private_address`, which lands in
`unsupported`. A step must never rescue `PoolBusy` (see apply_handlers.md): only the Runner and the job handle it.

**Shutdown.** `config.solid_queue.shutdown_timeout = 30.seconds` (`config/initializers/solid_queue_shutdown.rb`)
lets an apply step's `ensure` reach `Session#close` (the lease DELETE) on SIGTERM; the Kamal stop timeout of
`apply_worker` must be >= 40 s.

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
| `SCOPE_DEADLINE` (`Context::`) | 8 min | `Context#scope_deadline` = `min(now + 8 min, deadline_at)`, passed to `Session.open(deadline:)`; shorter than browserd `LEASE_TTL_S = 600` |
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
3. The handler's steps are cut into **units**: consecutive steps of one `session_scope` form a unit, a scope-less
   step is a unit of its own (`Run#units`).
   - **Scope-less step**: `condition` falsy → skip (no row). When its operation answers `input_digest(ctx, **options)`
     with a non-nil digest and `ApplyStep.where(apply_id:, key:, input_digest:, state: :succeeded).order(:attempt).last`
     exists (rides `index_apply_steps_resume_lookup`), the step is **skipped with restore**: no new row, the
     operation's `restore(ctx, row.result)` rebuilds the in-memory ctx, log `skipped (restore)`. A step without a
     digest (the whole legacy pipeline) runs every attempt.
   - **Scope unit** (atomic): scope `if:` falsy → no rows. It is skipped only when EVERY active step has such a
     row AND all those rows come from ONE attempt (restores run as the lookup goes, in order, so a later digest may
     read what an earlier restore rebuilt; a unit that then runs overwrites that state). Otherwise the whole unit
     re-runs, no matter which of its steps changed, inside **one** `ApplyMate::Client::Browser::Session.open(
     deadline: ctx.scope_deadline, owner: Session.owner_for(apply), humanize: scope == :submit,
     identity: apply.hashid)`; `ctx.open_scope!(scope, session, deadline)` publishes it to the stages and
     `ctx.close_scope!` runs in `ensure` (also when `Session.open` itself fails), so a stage never sees a released
     lease. A step exception passes through `Session.open` (lease released) after its row was closed.
   - Per step that runs: `ctx.check_fence!`; `ctx.remaining <= 0` → `Halt(:deadline)`;
     `FencedUpdate(stage: step.operation.stage)`, `ApplyStep.create!(attempt:, key: step.key, stage:, position:,
     scope:, input_digest:, state: :running, started_at:)`, `Broadcast`;
     `step.operation.call(ctx:, handler:, **step.options)`; `result.failure?` → `Halt(:invalid_record)`;
     success: row `succeeded`, `finished_at`, `result` = the operation's `result[:step_result]` and `trace` =
     `ctx.flush_trace!` (nil when empty), both through `RedactTree` (every string leaf through `Redact`, so a stored
     result never carries a secret; restore must tolerate that: `Redact`'s phone rule rewrites digit runs of ids and
     UUIDs, so a restore takes ids / URLs from the unredacted `applies` column its stage persisted, as DetectPlatform
     and ReachForm do). Failure (not `Fenced`): `CaptureArtifact(:failure)` while the session is still open, then
     the row becomes `failed` with `error_code`, redacted `error_detail` and the redacted trace; the exception
     continues up.
4. `Lifecycle::Finish`, or `Lifecycle::RecordHalt` for a `Halt` / mapped exception (`Decide`, one fenced UPDATE,
   `CloseSteps` for this attempt, broadcast, `Enqueue` on auto-resume).
5. `ensure`: ticker shutdown.

Logs carry `apply=<hashid> step=<key> attempt=<n>` (Runner) and `apply=<hashid> attempt=<n> halt=<code>`
(RecordHalt).

The keys of `apply_steps` rows come from `Handler::Base::Step#key` (`<stage>[:replay][:<scope>]`, see
apply_handlers.md); `(apply_id, attempt, key)` is unique, which is why one stage can run in two scopes.

### Failure artifacts

`Engine::CaptureArtifact.call(ctx:, step_record:, label:)` is what the Runner (`:failure`) and `Stage::Submit`
(`:before_submit`) call. No-op without `ctx.session_open?` or once `ctx.scratch.artifacts_count` reached
`ApplyStep::MAX_ARTIFACTS_PER_ATTEMPT = 8`. It attaches `session.screenshot(mask_fillable: true)` as `<label>.png`
and, for `:failure`, the HTML of each frame (`Redact`, `max_length: HTML_LIMIT = 512 KB`) as `<label>_f<i>.html` to
`step_record.artifacts`. It never raises (logged + `Rails.error`): evidence must not replace the error being
recorded. Access: `GET /artifacts/apply_step/:step_hashid/:position` runs `Artifact::Operation::Show` (owner
`apply_step`, `names: :artifact_at`: the 1-based position in `ApplyStep#ordered_artifacts`, attach order, never the
global attachment id; `ApplyStepPolicy` delegating to `ApplyPolicy`, `policy_scope` joins `applies` by
user); `RunTimelineAttempt` lists the links. `PruneApplySteps` purges them after `ARTIFACT_RETENTION`.

### Host slots (throttle)

`Stage::AcquireHostSlot` (stage `throttle`, no digest: a restored slot would defeat the throttle) takes
`ctx.platform.class.throttle` (`{ interval:, key: ->(ctx) }`) and runs ONE `INSERT ... ON CONFLICT (host_key) DO
UPDATE SET next_allowed_at = EXCLUDED.next_allowed_at, holder_apply_id = EXCLUDED.holder_apply_id WHERE
apply_host_slots.next_allowed_at <= now() OR apply_host_slots.holder_apply_id = EXCLUDED.holder_apply_id RETURNING
host_key` (primary key). A returned row = slot taken for `interval` (from now); none = `Throttled.new(until:
next_allowed_at)`. The holder clause exists because the step runs before the `:submit` scope opens its browser: a
`PoolBusy`, a halt before the claim (review, deadline, a gate) or any scope failure would otherwise throttle the
apply's own retry by its own reservation (other applies to the tenant still wait out the interval). A nil key skips
the throttle (traced). The Runner parks the apply (`waiting_capacity`) and `Apply::Job::Apply` retries at `until`
(`MAX_THROTTLE_WAITS = 12` throttled runs, counted apart from the PoolBusy retries, then `failed(:capacity)`). All
waiters of one tenant wake at the same `until` and one wins per interval, so a queue deeper than
`MAX_THROTTLE_WAITS` applies to ONE tenant ends with the tail in `failed(:capacity)` (Resume); sequential
reservations would need a per-apply reservation and are not built.

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
| `fetch_form` | `FetchInternalForm`, `Ai::FetchExternalForm` | `not_a_form`, `no_application_path`, `target_not_found`, `private_address` (AI `form_url`) |
| `fill_form` | `Ai::FillForm` | `invalid_ai_output` |
| `generate_cv` | `Ai::GeneratePdfCv` | — (`Apply.with_cv_or_generating_cv` keys on this string) |
| `submit` | `SendApply::Http`, `SendApply::Browser` | `outcome_unknown` (Http), `session_expired` (definitive), `validation_rejected` (not definitive), `target_not_found`, `required_field_unfillable` (Browser read-back, before the claim); Browser's unusable verdict leaks `EmptyResponse` / `InvalidResponse` → `invalid_ai_output` |

- Steps raise through `Apply::Operation::Base#halt!(code, detail:, definitive:)`.
- Claim placement: `SendApply::Http` claims after building the payload, right before `post_multipart`;
  `SendApply::Browser` claims after the fill read-back and the `present?(…, visibility: :required)` check of the
  submit button, right before the submit click. A missing trigger / submit button halts before the claim (`failed`).
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
first (`index_applies_stale_candidates`). The job behind a candidate is the **newest** `SolidQueue::Job` row with
`active_job_id = applies.job_id` (`where(...).order(:id).last`, `index_solid_queue_jobs_on_active_job_id`): every
`retry_job` inserts a new row under the same `active_job_id` and the finished ones stay until
`clear_finished_in_batches`, so an arbitrary row could be a finished earlier execution of a job whose retry is
still scheduled.

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

`Engine::PruneApplySteps` runs four bounded passes (`BATCH_SIZE = 1000` rows per statement, at most `MAX_BATCHES = 50` per pass):

1. **Artifacts**: `purge_later` for the `artifacts` of steps with `finished_at < ARTIFACT_RETENTION` (30 days; `index_apply_steps_on_finished_at` joined to the attachments).
2. **Steps**: delete steps with `finished_at < RETENTION` (180 days, `index_apply_steps_on_finished_at`; a row a lost run left `running` gets its `finished_at` from `CloseSteps`). The attachments of the rows about to be deleted are `purge_later`-ed first (`index_active_storage_attachments_uniqueness`), so no blob is orphaned.
3. **Traces**: `trace = NULL` for steps older than `TRACE_RETENTION` (90 days, partial `index_apply_steps_prunable_trace`); the row stays.
4. **Host slots**: delete `apply_host_slots` with `next_allowed_at < HOST_SLOT_RETENTION` (1 day; one tiny row per throttled host).

`applies` are never auto-deleted; destroying an apply removes its steps (`dependent: :destroy`).

## Apply::Field

`Apply::Field` (`app/concepts/apply/field.rb`, a `Data` subclass; design §7.1) is one fillable field of an application form. `Apply#fields` stores `field_list.map(&:to_h)`; `Apply#field_list` rebuilds them with `Apply::Field.from_h` (string or symbol keys). It replaces `Apply::FormField` / `form_data['inputs']` in phase 4; until then both exist.

| Member | Meaning |
| ------ | ------- |
| `id` | platform `field_key`, else `"f_" + signature + "_" + ordinal`; unique per inventory |
| `kind` | one of `Apply::Field::KINDS` (`text email tel url number textarea rich_text select multiselect combobox autocomplete radio_group option_group checkbox checkbox_group file date range hidden`) |
| `label`, `description`, `placeholder`, `required`, `multiple`, `max_length`, `accept` | form metadata |
| `autocomplete` | the control's `autocomplete` attribute from the snapshot (`BuildFieldInventory`; `nil` for schema-only fields), read by `Answer::Classify` |
| `options` | `[{ 'label', 'value' }]`, `'dynamic'` (loaded on open) or `nil` |
| `semantic` | one of `Apply::Field::SEMANTICS` (`full_name ... demographic legal_status password other`); `demographic`, `legal_status` and `password` never reach AI |
| `widget` | driver key chosen at discovery |
| `target` | where the field lives, valid for ONE session: `ApplyMate::Client::Browser::Target` (an HTTP form target arrives with the phase-4 `FormField` replacement). `to_h` writes `'type' => 'browser'`; `from_h` picks the class through `TARGET_TYPES` (constantized once) |
| `signature`, `ordinal` | identity across sessions: `signature` = `Apply::Field.signature_for(label:, kind:, option_labels:)` (SHA1 of the downcased, whitespace-squished parts; the ONE implementation), `ordinal` = position among equal signatures in DOM order. A stored `target` is never an identity |
| `default_value` | prefilled value read in the current session; `to_h` drops it for `hidden` fields (CSRF etc.) |
| `condition` | `{ 'field' => id, 'equals' => value }` or `nil` |
| `source` | one of `Apply::Field::SOURCES` (`schema_api snapshot`; `html_form` arrives in phase 4) |

Predicates: `file?`, `fillable?` (not hidden), `option_kind?` (`OPTION_KINDS`), `textarea?` (`textarea`, `rich_text`),
`multi_valued?` (`MULTI_KINDS` = `multiselect checkbox_group`, or `multiple == true` on any other kind: Ashby
`MultiValueSelect`, the DOM `multiple` attribute). `multi_valued?` is the ONE "takes a list" check: `CoerceValue`,
`ResolveConsent`, the review form and `Widget::OptionGroup` all use it.

`Apply#question_labels` feeds the VacancyQuestion suggestions: labels of `textarea`/`rich_text` fields that have a label; while `fields` is blank it falls back to the legacy `Apply::FormField` inputs (branch deleted in phase 4 with `form_data`). `Apply#answer_for(field_id)` reads `answers[field_id]` (`{ value, source, confidence }`); `Apply#platform_known?` is `platform.present? && platform != 'generic'`.

### Engine columns (phase 3a)

| Table | Columns |
| ----- | ------- |
| `applies` | `platform`, `platform_match` (jsonb), `apply_key` (`index_applies_on_user_apply_key`, partial `apply_key IS NOT NULL`: the already-applied check), `entry_url`, `form_url`, `navigation` (jsonb), `fields` (jsonb), `answers` (jsonb), `answers_approved_digest`, `reviewed_at`, `duplicate_confirmed_at` |
| `apply_steps` | `scope`, `input_digest`, `trace` (jsonb), `artifacts` (Active Storage, at most `ApplyStep::MAX_ARTIFACTS_PER_ATTEMPT = 8`); partial `index_apply_steps_resume_lookup (apply_id, key, input_digest) WHERE state = 1` (keyed by `key`, not `stage`: one stage runs in two scopes) and `index_apply_steps_prunable_trace` |
| `apply_host_slots` | `host_key` (primary key), `next_allowed_at` (per-tenant throttle), `holder_apply_id` (the apply that took it; no index or FK, read through the primary-key row only) |
| `user_profiles` | `facts` (jsonb `{ 'ai' => {...}, 'user' => {...} }`), `facts_cv_digest` (SHA256 of the CV the facts came from) |
| `users` | `review_policy` (enum `always 0`, `unknown_platforms 1`, `never 2`; default `never`), `auto_consent` (boolean, default `true`) |

### Profile facts

`UserProfile::Operation::ExtractFacts` makes one AI call and stores the result under `facts['ai']`. Two callers: the job `UserProfile::Job::ExtractFacts` (queue `:apply`, enqueued by profile Create/Update when `saved_change_to_cv?`; the user's default AI integration, none -> facts stay `nil`; `retry_on` `EmptyResponse` / `InvalidResponse` / `GeminiScraping::ResponseTimeoutError` / `Faraday::Error`, 3 attempts, `polynomially_longer`) and `Stage::AnswerFields` (inline before `Answer::Resolve`, with `apply.ai_integration`), so a profile whose facts were never extracted (created before the column, saved without an integration, a job out of retries) gets them at its next apply: no absorbing "facts nil" state. It returns early while `facts_cv_digest` equals the CV digest. A re-extraction replaces only `facts['ai']`; `facts['user']` is kept and `UserProfile#fact(key)` returns the user value before the AI value.

## Context scratch

`Context` members are immutable; what the stages learn during ONE run lives in `ctx.scratch`
(`Context::Scratch` Struct: `session scope scope_deadline platform match evidence schema fields form_root form_url
trace platform_switches claim_mark artifacts_count consent_clicks http canonical_unwrapped step_record`, built by
`Scratch.fresh` in `Context#initialize`, so every `StartContext` run starts empty), shared by copies made with `#with`
and never persisted as a whole. Helpers:

| Helper | Meaning |
| ------ | ------- |
| `session`, `session=`, `session_open?` | the open browser scope's Session; `session=` resets the CookieConsent budget and `canonical_unwrapped` (one canonical navigation per platform per session) |
| `platform`, `match`, `platform_known?` | adopted adapter instance and its `Detect::Match`; `platform_known?` falls back to `apply.platform_known?` |
| `adopt_match!(match)` | sets the match and instantiates `Registry.find!(match.key).new(ctx:, match:)` |
| `redetect!(evidence)` | merges evidence, re-runs `Detect`; same key → re-adopted (richer captures), generic result never demotes a known platform, a different platform switches at most `MAX_PLATFORM_SWITCHES = 2` times per run (each `platform_switch` / `platform_switch_capped` traced) |
| `entry_url` | `apply.entry_url` or `apply.vacancy.external_url` |
| `schema`, `schema_keys`, `fields`, `form_root`, `form_url`, `form_host` | what the stages found; `schema_keys` strips the `"<platform key>:"` prefix of schema ids |
| `remaining`, `clamp(seconds)`, `scope_deadline` | time left (min of run deadline and open scope deadline), timeouts never past it |
| `persist!(**attrs)` | `FencedUpdate` + in-memory assignment (no reload) |
| `trace(event, **data)` | in-memory trace, newest `MAX_TRACE = 100` kept; the Runner redacts on flush |
| `http` | the run's `ImpersonateHttp.new(request_timeout: HTTP_TIMEOUT = 15)`, built once |

## Handler::Dou routing

```ruby
add_step Apply::Operation::CheckApplyable
add_step Apply::Operation::FetchApplyType
engine! detect_if: ->(ctx) { ctx.apply.external? }, if: ->(ctx) { ctx.apply.external? && ctx.platform_known? }
# TEMPORARY legacy external path (deleted in phase 3b with the Navigator):
add_step Apply::Operation::Ai::FetchExternalForm, if: ->(ctx) { ctx.apply.external? && !ctx.platform_known? }
add_step Apply::Operation::FetchInternalForm,      if: ->(ctx) { ctx.apply.internal? }
add_step Apply::Operation::Ai::FillForm,      if: ->(ctx) { ctx.apply.internal? || !ctx.platform_known? }, ...
add_step Apply::Operation::Ai::GeneratePdfCv, if: ->(ctx) { ctx.apply.internal? || !ctx.platform_known? }, ...
add_step Apply::Operation::SendApply::Browser, if: ->(ctx) { ctx.apply.external? && !ctx.platform_known? }
add_step Apply::Operation::SendApply::Http,    if: ->(ctx) { ctx.apply.internal? }
```

- **External, known platform** (`ctx.platform_known?`: the match, or the persisted `applies.platform`, is not
  `generic`): `detect`, then the engine stages below; `FetchExternalForm` / `FillForm` / `SendApply::Browser` never
  run. A generic HTTP match with a `probable` known platform (Preply: `preply.com/...?ashby_jid=`) still runs
  `schema` and the `:survey` scope (`ctx.platform_reachable?`), whose ReachForm identifies Ashby on the rendered
  landing page; from there the run is "known".
- **External, unknown platform** (`generic`, no probable platform: PeopleForce in the HoneyTech specs): only
  `detect` runs from the engine (it persists `platform: 'generic'`), then the legacy path exactly as in phase 2:
  `fetch_form fill_form generate_cv submit`.
- **Internal**: unchanged (`check_applyable fetch_apply_type fetch_form fill_form generate_cv submit`).
- `generate_cv` is declared twice (engine! and legacy) with mutually exclusive conditions; `apply_steps` is unique on
  `(apply_id, attempt, key)`, and `dou_spec.rb` ("step conditions") asserts for every combination of
  external/known/probable that no two active steps share a key and exactly one `generate_cv` runs.
- `Apply::Handler::Djinni` is unchanged (phase 4).

## Stages of phase 3a

Declared by `Handler::Base.engine!` (`apply_handlers.md`, "Session scopes and `engine!`"), in run order. "Digest":
the step is skipped with `restore` when a succeeded row with the same key and `input_digest` exists (Runner);
"always" = no digest. Scopes are atomic units with one lease each (`humanize: true` only for `:submit`).

| Key | Stage | Scope | Digest (input) | Halts |
|---|---|---|---|---|
| `detect` | `Stage::DetectPlatform` | — | entry URL + `Registry.fingerprint` | `no_application_path` (no entry URL, > `MAX_HOPS` redirects), `already_applied`, http gates (`manual_apply_required`/`google_forms`, `external_messenger`, `login_required`, `bot_wall`, `private_address`) |
| `schema` | `Stage::FetchSchema` | — | match key + captures | — (`SchemaUnavailable` → no schema, DOM fallback) |
| `navigate:survey` | `Stage::ReachForm` | `:survey` (only while `ctx.survey_needed?`) | match key + captures + schema ids | `not_a_form`, `already_applied` (after a platform switch), rendered gates (`manual_apply_required`/`captcha`, ...) |
| `discover:survey` | `Stage::DiscoverFields` | `:survey` | match + schema ids + `Registry.fingerprint` | after_goto gates |
| `answer` | `Stage::AnswerFields` | — | field list, CV digest, `facts['user']`, name, email, `auto_consent`, prompt template + id | `invalid_ai_output` (Runner mapping) |
| `generate_cv` | `Ai::GeneratePdfCv` | — | always | — |
| `review` | `Stage::ReviewGate` | — | always | `review` (→ `needs_review`) |
| `throttle` | `Stage::AcquireHostSlot` | — | always | none; raises `Engine::Throttled` (→ `waiting_capacity`, retried by `Job::Apply` up to `MAX_THROTTLE_WAITS`, then `capacity`) |
| `navigate:replay:submit` | `Stage::ReachForm replay: true` | `:submit` | always | `not_a_form` |
| `discover:submit` | `Stage::DiscoverFields reconcile: true` | `:submit` | always | after_goto gates |
| `fill:submit` | `Stage::FillFields` | `:submit` | always | `required_field_unfillable`, `review`, `wizard_too_long`, `no_widget_driver`, `target_obstructed` |
| `submit:submit` | `Stage::Submit` | `:submit` | always | before the claim: `deadline` (< `SUBMIT_RESERVE` = 120 s left), before-submit gates, `target_not_found`; after the claim every halt is `submit_unverified` |
| `verify:submit` | `Stage::Verify` | `:submit` | always | `validation_rejected`, `outcome_unknown` (→ `submit_unverified`) |

A resumed attempt after `needs_review` + `ApproveReview` skips `detect`, `schema`, the `:survey` scope and `answer`
(restored) and runs `generate_cv` (no digest yet) through `verify:submit`.

## Platform adapters (DSL)

An adapter (`app/concepts/apply/platform/*.rb`, `Apply::Platform::Base` subclass) is DATA about one ATS / form host
(design §4.1, §5.1). It never drives the browser; stages call engine operations and ask the adapter for providers
and hooks. Real work (an HTTP schema read) is an operation (`Apply::Operation::Platform::<Name>::*`).

Class-level DSL:

| Declaration | Meaning |
| ----------- | ------- |
| `signal kind, pattern, weight:, captures: []` | `Signal = Data.define(:kind, :pattern, :weight, :captures)`; `SIGNAL_KINDS = %i[host url query_param frame_src script_src dom]`. `query_param` pattern is the parameter name, `dom` a CSS selector (counted by `detect.js`), the rest Regexps with named captures |
| `required_captures :slug, :jid` | a match lacking any of them is capped at `THRESHOLD - 0.01` |
| `priority n` | tie-break on equal confidence (default 100) |
| `throttle interval, key: ->(ctx) { ... }` | min interval between submits per tenant (`AcquireHostSlot`); `DEFAULT_THROTTLE` 10 min keyed `host:<form_host>` |
| `extra_gates`, `skipped_gates` | adjust `Apply::Gate::Registry::DEFAULT` for this platform |
| `key` | `name.demodulize.underscore` (`ashby`) |

Every declaration except `signal` falls back to the superclass (a spec subclass of Ashby keeps
`required_captures`, `throttle`, gates); `signals` are per class, so such a subclass re-declares them.

Instance (`new(ctx:, match:)`, built by `Context#adopt_match!`):

- Providers (nil = engine default): `canonical_form_url`, `fetch_schema` (`[Apply::Field]`, source `schema_api`),
  `navigation_recipe` (3b), `answer_override(field)`, `readiness` (`Base::Readiness.visible_fields(min:, root:)` or
  `.schema_keys(keys:, attr:, ratio: 0.8, root:, key_prefix: nil)`; `key_prefix` is the platform's per-render prefix of
  the `attr` values as ONE regex source valid in Ruby and JS, shared with its `field_key`), `apply_key`.
- Hooks with defaults: `excluded_regions` (`[]`), `form_root_selector` (nil), `field_key(raw)` (`raw.default_key`;
  `raw` is `Base::RawField(element, default_key)` with `#attr(name)` over the snapshot element's `attrs`),
  `answer_hints` (`{}`), `semantic_for(field)` (nil; the semantic a platform field key names, Ashby `_systemfield_*`;
  `Answer::Classify` asks first), `fill_order(fields)` (identity), `success_evidence`
  (`{ texts:, url_patterns:, submit_request: { url:, body_ok: } | nil, min_signals: }`), `gates`.
- No transport / action methods (`reach_form`, `fill`, `submit` ...) on the adapter in 3a.

`Apply::Platform::Generic` (key `generic`, no signals, `readiness` → `:ai_only`) is what `Detect` returns below the
threshold. In 3a an unknown platform keeps the LEGACY external path; navigation arrives in 3b.

`Apply::Platform::Registry`: `PLATFORMS = %w[Apply::Platform::Ashby]`, `BOARD_PLATFORMS = []` (phase 4, pinned, never
detected), `THRESHOLD = 0.8`, `FINGERPRINT_VERSION = 1`; memoized `platforms`, `dom_markers` (selectors of all
`:dom` signals), `known_hosts` / `known_host?(host)` (`:host` signal patterns), `fingerprint` (SHA256 of version +
key/priority/signals; part of `DetectPlatform.input_digest`), `find!(key)` (Generic for `generic`, `ArgumentError`
otherwise).

### Ashby

`Apply::Platform::Ashby` (design §5.3). Every URL and pattern comes from `self.origin`
(`https://jobs.ashbyhq.com`): `job_url`, `graphql_url`, `canonical_form_url`, the schema endpoint. A spec subclass
overrides `origin` and calls `declare_signals!` to point the adapter at FixtureSite (no production flag).

| | |
|---|---|
| signals | host `jobs.ashbyhq.com` 0.7; url / frame_src `<origin>/<slug>/<jid>` 0.95 (slug, jid); script_src `<origin>/<slug>/embed` 0.85 (slug); query_param `ashby_jid` 0.6 (jid); dom `.ashby-application-form-field-entry` 0.9 |
| required_captures | `slug`, `jid` |
| throttle | 10 min keyed `ashby:<slug>` |
| canonical_form_url | `<origin>/<slug>/<jid>/application` |
| fetch_schema | `Apply::Operation::Platform::Ashby::FetchSchema` (below); `Apply::Platform::SchemaUnavailable` → traced `schema_unavailable`, nil (the DOM is read) |
| field_key | `ashby:` + `data-field-path` of the field root, else `name`, with the per-render instance UUID prefix (`INSTANCE_PREFIX`, built from `INSTANCE_PREFIX_SOURCE`) stripped; else the default key |
| form_root_selector / excluded_regions | `#form[role="tabpanel"]` / `.ashby-application-form-autofill-input-root` (the autofill-from-resume pane) |
| fill_order | files first (the resume upload re-renders the form) |
| readiness | `schema_keys` on `data-field-path` under the form root, once a schema is known; `key_prefix: INSTANCE_PREFIX_SOURCE` (the same source as field_key) |
| success_evidence | two texts + `submit_request` on `<origin>/api/non-user-graphql` with `body_ok: errors blank && data present`, `min_signals: 2` |
| apply_key | `ashby:<slug>:<jid>` |

`Apply::Operation::Platform::Ashby::FetchSchema.call(slug:, jid:, http:, origin:)` POSTs the SPA's own persisted
query (`api_job_posting.graphql`, `operationName: 'ApiJobPosting'`) to `<origin>/api/non-user-graphql?op=ApiJobPosting`
through `GuardedFetch` (one pinned request, no redirects). Non-2xx, invalid JSON, GraphQL errors, no
`applicationForm`, no entries, or a curl failure → `SchemaUnavailable`. Each visible field entry becomes one
`Apply::Field` (id `ashby:<path>`, each path once, `semantic` / `target` nil). Kinds: String→text, Email→email,
Phone→tel, File→file, Number→number, LongText→textarea, ValueSelect→combobox with ≥ `COMBOBOX_MIN_OPTIONS = 6`
options else radio_group, MultiValueSelect→checkbox_group, Boolean→radio_group (Yes/No), Date→date,
Location→autocomplete, unknown→text.

## Detection

`Apply::Operation::Engine::Detect.call(evidence:)` → `Detect::Match` (design §4.1). Per platform: for each signal kind
the highest weight among matching signals; kinds combine by noisy-or (`1 - Π(1 - w)`); captures of all matching
signals merge (stronger wins). Where each kind looks:

| Kind | Evidence |
| ---- | -------- |
| `host`, `url`, `query_param` | `current_urls` only (final URL of the redirect chain, frame URLs); intermediate `hops` (dou.ua/goto) never score |
| `frame_src` | `iframe_srcs` (the matched text becomes `Match#frame_path` `[{ 'url_contains' => ... }]`) |
| `script_src` | `script_srcs` |
| `dom` | `dom_markers` (selector → count) |
| host alias | `host_aliases` at `HOST_ALIAS_WEIGHT = 0.5` (learned recipes, phase 6; always empty in 3a) |

Missing `required_captures` cap the confidence at `THRESHOLD - 0.01`. Best by `[confidence, priority]`; below
`THRESHOLD` → `Match.generic(probable: best)`.

`Detect::Evidence = (current_urls, hops, script_srcs, iframe_srcs, dom_markers, host_aliases)`; `.empty`, `.build`,
`.from_snapshot`, `.from_h`, `#merge` (union, larger marker count), `#to_h`; every list capped at `MAX_ENTRIES = 200`.
`Detect::Match = (key, confidence, captures, frame_path, from_alias, probable)`; `.generic(probable:)`, `.from_h`,
`#to_h`, `generic?`, `known?`.

Two levels:

- HTTP (`CollectHttpEvidence.call(entry_url:, http:)`, before any browser lease): redirect walk through
  `ApplyMate::Net::Operation::GuardedFetch` one hop at a time (each Location resolved against the previous URL,
  guarded and pinned); at most `MAX_HOPS = 5` redirects, a 6th → `Halt(:no_application_path, 'redirect loop')`;
  an invalid Location → `no_application_path`. The final 2xx HTML page is scanned (Nokogiri) for `script[src]` /
  `iframe[src]`; a Cloudflare interstitial gives URLs only (the rendered level redetects). A hop curl cannot fetch
  (`ImpersonateHttp::RequestError`: timeout, reset, TLS) ends the walk there as the final URL without HTML evidence;
  `result[:fetch_error]` says why and DetectPlatform traces it in `http_evidence` (a slow site must not fail the
  apply at the head-start level). `UnsafeUrlError` is never rescued.
- Rendered (`CollectRenderedEvidence.call(session:, snapshot: nil)`): `session.snapshot_all(markers:
  Registry.dom_markers)` → every frame URL is a current URL, plus srcs and marker counts. Callers feed it to
  `ctx.redetect!`.

Example (Preply): dou.ua → `preply.com/...?ashby_jid=<jid>` scores only `query_param` 0.6 without slug → generic
(probable ashby 0.6); the rendered `iframe#ashby_embed_iframe` src `jobs.ashbyhq.com/preply/<jid>` adds frame_src
0.95 with slug + jid → ashby ≥ 0.95. If the careers page HTML already carries the embed script, script_src (slug) +
query_param (jid) give ashby 0.94 at the HTTP level.

## Gates

A gate (`app/concepts/apply/gate/*.rb`, `Apply::Gate::Base`) is a known obstacle checked at fixed events. It returns
nil, resolves in place (truthy), or raises `Halt`. Gates stop ONE apply and never write shared state. Run them with
`Apply::Operation::Engine::RunGates.call(ctx:, event:, evidence: | snapshot:)` (model = names of gates that resolved
something). `Apply::Gate::Registry.for(platform_class)` = `DEFAULT + extra_gates - skipped_gates`, constantized once
(Concurrent::Map); before detection the Generic list is used.

Events (`Base::EVENTS`): `http_resolved` (after the redirect walk, evidence only), `after_goto`, `after_action`,
`before_submit`, `after_submit` (snapshot; evidence derived from it).

| Gate (DEFAULT order) | Events | Trigger | Result |
| -------------------- | ------ | ------- | ------ |
| `PrivateAddress` | http_resolved, after_goto | a current URL / hop on localhost or a literal private IP (no DNS; GuardedFetch already checked HTTP hops) | `Halt(:private_address)` |
| `GoogleForms` | http_resolved, after_goto | any hop / current URL on `forms.gle` or `docs.google.com/forms` | `Halt(:manual_apply_required, detail: :google_forms)` (§18: "apply yourself") |
| `ExternalMessenger` | http_resolved, after_goto | main URL on `t.me`, `telegram.me`, `wa.me`, `m.me` (embedded frames ignored) | `Halt(:external_messenger)` |
| `SignInWall` | http_resolved, after_goto, after_action | main URL on `OAUTH_HOSTS` (accounts.google.com, login.microsoftonline.com, linkedin.com/oauth, linkedin.com/uas/login, github.com/login), or a visible password field in the snapshot | `Halt(:login_required)` |
| `DataDome` | http_resolved, after_goto | `captcha-delivery.com` in hops / current URLs / scripts / frames, or snapshot captcha `datadome` | `Halt(:bot_wall)` |
| `CookieConsent` | after_goto, after_action | a visible enabled button whose whole name matches `CONSENT_LEXICON` (necessary / essential only, reject all; uk + en), else `LAST_RESORT` (accept all) | clicks it (`session.click` + `settle(:click)`), never raises; at most `MAX_CLICKS = 2` per session |
| `VisibleCaptcha` | after_action, before_submit | snapshot captcha `recaptcha`, `recaptcha_challenge`, `hcaptcha`, `turnstile` (invisible kinds ignored) | `Halt(:manual_apply_required, detail: :captcha)` (§18) |

GoogleForms runs before SignInWall so a Google Form redirecting to accounts.google.com is "apply yourself", not
"login required".

## Stages: DetectPlatform, FetchSchema

`Apply::Operation::Stage::Base < Apply::Operation::Base` adds `self.input_digest(ctx, **)` (nil = always run; else a
succeeded step row with the same digest lets the Runner skip and call `self.restore(ctx, result)`) and
`step_result(**data)` (stored by the Runner in `apply_steps.result`, see Runner).

| Stage | key | Flow | input_digest | restore |
| ----- | --- | ---- | ------------ | ------- |
| `DetectPlatform` | `detect` | `CollectHttpEvidence` → `RunGates(:http_resolved)` → `ctx.redetect!` → `CheckApplyKey` → `persist!(platform:, platform_match:, apply_key:, entry_url:, landing_url:)` (`landing_url` = the walk's final URL, unredacted; `Context#landing_url` reads it, else the entry URL); step_result `{ match, evidence }`. No entry URL → `no_application_path` | SHA256 of entry URL + `Registry.fingerprint` | re-adopts the match (from the unredacted `applies.platform_match` when it names the same platform, else the result); rebuilds the evidence with `current_urls: [applies.landing_url]`, the stored `hops` / `dom_markers`, and NO `script_srcs` / `iframe_srcs` / `host_aliases` (never URL evidence from the redacted result) |
| `FetchSchema` | `schema` | `ctx.platform.fetch_schema`; non-empty → `ctx.schema`, `persist!(fields:, form_url: canonical_form_url)`; step_result `{ fields: n }` | SHA256 of match key + captures | `ctx.schema` = `apply.field_list` with source `schema_api` |

`CheckApplyKey.call(ctx:)` (design §11.2): key = `platform.apply_key` || normalized form URL (`host/path`, no `www.`,
query, fragment or trailing slash) || nil (never the entry URL: a board redirector would make every vacancy one key).
Another apply of the same user with that key in `completed` / `submit_unverified` or holding a submit claim →
`Halt(:already_applied, detail: <previous hashid>)` unless `duplicate_confirmed_at` is set. Rides
`index_applies_on_user_apply_key`.

## Answers and review

Two stages and a family of operations under `Apply::Operation::Answer::*` (all internal: `skip_authorize`, no browser).

| Stage | key | What it does | input_digest | restore |
| ----- | --- | ------------ | ------------ | ------- |
| `Stage::AnswerFields` | `answer` | `Answer::Resolve` -> `persist!(answers:, fields:)` (the field list with `semantic` filled in); step_result `{ answers: n }`. Missing / stale profile facts are extracted inline first (`UserProfile::Operation::ExtractFacts`, `apply.ai_integration`). No fields: nothing happens | SHA256 of field ids / kinds / options / required / condition plus the semantic each field classifies to now (`Answer::Classify` with `ctx.platform`, so a lexicon / autocomplete / platform-key change re-classifies; the stored semantic is ignored, so persisting it does not change the digest), `Registry.fingerprint` (in `DiscoverFields`' digest too: a re-discovery that reset the semantics to nil re-runs this stage), the CV digest (not `facts['ai']`: it is derived from the CV inside run!, and its first extraction must not turn a resume into a re-answer that voids an approved review), `facts['user']`, the profile name, `user.email`, `user.auto_consent`, the prompt template and `fill_form_prompt_id` | no-op: the answers live in `applies.answers` |
| `Stage::ReviewGate` | `review` | `Answer::ReviewRequired`; required -> `Halt(:review, detail: reasons.join(','))` (needs_review, the reasons sit in `failure.detail` for the review form); step_result `{ reasons: [...] }` | nil (always runs, it is cheap) | - |

`AnswerFields` may use a `GeminiScraping` integration: the browser lease is closed while answers are made (survey and
submit are separate session scopes), so the "one thread, one browser" invariant holds.

### Resolution order (`Answer::Resolve`)

`applies.answers = { field_id => { 'value', 'source', 'confidence' } }`, sources `override fact policy policy_pending ai approximate user`.
Per fillable field, the first rule that applies wins; a field whose `condition` is unmet gets no answer.

1. An answer with source `user` from an earlier review is kept as it is.
2. `platform.answer_override(field)` -> `override`.
3. `Answer::Classify` gives the `semantic` (persisted back onto the field): platform key (`Platform::Base#semantic_for`,
   Ashby `_systemfield_*`) -> `password` flag -> `file` kind (cv) -> `email` / `tel` kind -> `field.autocomplete` (`Classify::AUTOCOMPLETE`) ->
   label (then placeholder) against `config/apply/field_semantics.yml` (uk / en / ru regexes, first semantic wins,
   sensitive ones first, a regex under one semantic only) -> `other`. The text is normalized first
   (`Classify::TRAILER`: trailing `* : . ? !` and a trailing `(...)` note cut). Profile-fact patterns (names, email,
   phone, location) are anchored to the whole label and `consent_required` names consent wording only, because both
   are answered at confidence 1.0 with no review reason: "Are you open to relocation?", "Name of your current
   employer" or "Do you agree to work from the office?" must reach the AI as `other`. Nationality / national origin
   are `demographic`, citizenship is `legal_status`.
4. **Sensitive semantics never reach the AI.**
   `password` -> `Halt(:login_required)`; `demographic` -> the user's explicit `demographic` fact (matched to the
   options), else the "decline to self-identify" option (`decline` lexicon, source `policy`), else empty when optional /
   `Halt(:missing_profile_fact, detail: field id)` when required; `legal_status` -> the `work_authorization` fact only,
   else the same empty / halt.
5. Profile facts (`Answer::ResolveFact`: `UserProfile#fact`, `email` falls back to `user.email`, `full_name` to the profile
   name, languages are joined; `cv` -> `Answer::FileRef.cv`, stored as `{ 'file' => 'cv' }`). A fact that does not fit
   the field's options goes to the AI instead. A file field with any other semantic (a platform key mapping it to
   `cover_letter`, ...) never reaches the AI: empty when optional, `Halt(:missing_profile_fact)` when required (an AI
   string would become an upload path; `Stage::FillFields` also uploads only a `FileRef`, never a string answer).
6. Consent (`Answer::ResolveConsent`): `consent_required` -> checkbox `true`, or the option `Engine::MatchOption` finds for
   the `affirm` lexicon (`Classify.option_label_for`, the one phrase-to-option rule, also used for the `decline` option;
   a list when `field.multi_valued?`); source `policy` when `users.auto_consent` (default **true**, design
   §18.3), `policy_pending` when the user opted out. No affirmative option: a required field gets
   `{ value: nil, source: policy_pending }` and the user fills it in the review form; an optional one stays empty.
   `marketing_opt_in` is never set (`Answer::Resolve` returns nil for it; `ResolveConsent` only sees `consent_required`).
7. Everything else, in ONE AI call (`Apply::Ai::Prompt::AnswerFields`, schema `Apply::Ai::ResponseSchema::AnswerFields`, kind
   `:answers`): fields as id / kind / label / description / options / required / max_length plus
   `platform.answer_hints` (`{ field_id => text }`), the vacancy text and every field description inside
   `<<<UNTRUSTED_PAGE_CONTENT>>>` markers, the CV and the non-sensitive facts (`PROMPT_FACTS`; never `work_authorization`
   or `demographic`). The template is `apply.fill_form_prompt&.content || PROMPT_TEMPLATE` with the legacy
   `PLACEHOLDER_*` names. Each answer goes through `Answer::CoerceValue` (the one value check, shared with
   `ApproveReview`): options are replaced by the matched option label, numbers coerced, text cut to `max_length`, a
   required blank is an error. An invalid set is asked again ONCE with the error list; a second failure is
   `Halt(:invalid_ai_output)`.

`Engine::MatchOption.call(candidates:, wanted:)` is the one answer <-> option rule: exact normalized label / value ->
boolean synonyms (yes / true / 1 / так / да vs no / false / 0 / ні / нет) -> containment on word boundaries -> token
overlap (Jaccard >= 0.6); steps after the first answer only when exactly one candidate qualifies, ambiguity is nil.
`MatchOption.same?(displayed, wanted)` is the same rule for a read-back.

### Review

`Answer::ReviewReasons` (symbols) and `Answer::ReviewRequired` (`reasons.any?` AND `answers_approved_digest != Digest`):

| Reason | When | Kind |
| ------ | ---- | ---- |
| `policy_always` | `users.review_policy` is `always` | policy (default `never` skips it) |
| `unknown_platform` | `review_policy` is `unknown_platforms` and the platform is unknown (unreachable in 3a) | policy |
| `low_confidence` | an `ai` answer with confidence < 0.5 | safety |
| `approximate` | an answer picked as the nearest option | safety |
| `consent_pending` | a `policy_pending` answer (user opted out of `auto_consent`) | safety |
| `foreign_origin` | the registered domain (`PublicSuffix`) of `form_url` is not a known platform host and not one of the entry URL / detection hops / landing URLs | safety |
| `duplicate` | `CheckApplyKey.previous_apply` finds an earlier submitted apply of the same key and `duplicate_confirmed_at` is nil | safety |

Safety reasons force review whatever the policy is. `Answer::Digest` is the SHA256 of the canonical JSON of the answers
(sorted keys, value and source only): an approval is bound to the exact answers the user saw, so a later change (new AI
answer, approximate pick) re-opens the review. Locale texts: `apply.review.reason.<reason>`.

`Apply::Operation::ApproveReview` (`POST /applies/:id/approve_review`, `ApplyPolicy#approve_review?` = owner) takes
`params[:answers]` (`{ field_id => value }`, edited fields only, unknown ids and file fields ignored, blank array
entries dropped; each value is checked with
`CoerceValue`, a required field may not end blank) and `params[:confirm_duplicate]` (required when the review was opened
by `already_applied`). Edits become source `user`, and so does every `policy_pending` answer (approving is the consent).
ONE state-guarded `UPDATE ... WHERE id AND state = needs_review` writes `answers`, `answers_approved_digest = Digest`,
`reviewed_at`, `duplicate_confirmed_at`, `state: queued`, `stage: nil`, `failure: nil`; 0 rows (a concurrent cancel or expiry)
-> `apply.approve_review.not_allowed`. Then `Engine::Enqueue`, `touch_user_applies_changed_at!` and `Engine::Broadcast`.

## Snapshot and form elements

`session.snapshot_all(markers:, regions:)` (`.ai/docs/browser.md`) is the ONE definition of "an interactive element":
`ApplyMate::Client::Browser::Snapshot = Data.define(:frames, :elements, :evidence, :digest)`, every frame up to
`MAX_FRAMES = 20` including cross-origin iframes and open shadow roots. Each element hash carries `ref`, `tag`, `type`,
`role`, `name` (accessible name), `question`, `group` / `group_key` / `options` (radio / option groups, comboboxes),
`attrs` (`id name type autocomplete placeholder accept multiple maxlength value data-field-path`), `chip`, `href`,
`required`, `filled`, `visible`,
`disabled`, `password`, `search_like`, `submit_like`, `regions` (which of the requested `regions` selectors contain it),
`root_strategies` (the field root) and `target` (an `ApplyMate::Client::Browser::Target` with its `frame_path`).

`Engine::FormElements.snapshot(ctx)` asks for the regions `[form_root css, *platform.excluded_regions]`;
`FormElements.call(ctx:, snapshot:)` keeps the elements whose `target.frame_path == form_root.frame_path`, whose
`regions` include the form root selector and none of the excluded regions (`Halt(:not_a_form)` without a form root).
Inventory, FillFields' submit-button check and Submit all read the page through it.

## Reach form

`Stage::ReachForm` (key `navigate`) → `Engine::ReachForm.call(ctx:)`, model = the navigation (array of op hashes):

1. **unwrap_canonical** — `platform.canonical_form_url` present, not yet unwrapped for this platform in this session
   (`ctx.scratch.canonical_unwrapped`), and not the current page by `CheckApplyKey.normalized_url` (host + path) →
   `Apply::Recipe::Op::Unwrap('{canonical_form_url}')`.
2. **run_recipe** — `platform.navigation_recipe` (array of op hashes) parsed by `Apply::Recipe::Op::Base.parse!`.
3. **current page** — nothing navigated and the lease is not on `about:blank` → readiness check on the page as is
   (navigation `[]`; e.g. the embed iframe of a company page).

After every op: `snapshot_all` → `RunGates(:after_goto)` → `CollectRenderedEvidence` → `ctx.redetect!` (trace
`navigated`). Each path then waits `WaitReady(timeout: ctx.clamp(READY_TIMEOUT = 30))`; ready → `ctx.form_root`,
`ctx.form_url = session.current_url`. No path ready → `Halt(:not_a_form, detail: 'form not reached')`. Each path waits
once, so the stage stops after at most two readiness windows when the page never becomes a form. The Navigator (AI
navigation for unknown platforms) is phase 3b: until then an unknown platform keeps the legacy external path.

**Recipe ops** (`app/concepts/apply/recipe/op/`, phase 3a ships only these): `Base` (`OPS` map, `parse!`, `to_h`,
`url(ctx)` resolving `{entry_url}`, `{canonical_form_url}`, `{current}`; an unknown op / placeholder or a placeholder
without a value raises `ArgumentError`), `Goto` and `Unwrap` (both `session.goto(url)`). Interpreter, `expect` and drift
detection arrive in 3b.

**`WaitReady.call(ctx:, timeout:)`**: readiness = `platform.readiness` or
`Readiness.visible_fields(min: 3, root: form_root_selector || 'body')`. Inside ONE `session.wait_until(timeout:)` it
polls `session.ready?(root, timeout: 0, keys:/attr:/ratio:/key_prefix:` or `min_fields:)` in the top frame and every `http(s)` frame
(first `MAX_FRAMES`, child frames addressed by `url_contains`); model = the root `Target`, its `frame_path` taken from
the snapshot (`iframe#id` hop for the Ashby embed), or nil when the window ends.

| Stage | key | Flow | input_digest | restore |
| ----- | --- | ---- | ------------ | ------- |
| `ReachForm` | `navigate` | `Engine::ReachForm`; `persist!(navigation:, form_url:)`; step_result `{ navigation, form_url, form_root }` | SHA256 of match key + captures and schema ids; nil with `replay: true` (always re-runs: the canonical unwrap is idempotent, stored recipe replay is 3b) | `form_url` from `applies.form_url`, `form_root` from the result |
| `DiscoverFields` | `discover` | `FormElements.snapshot` → `RunGates(:after_goto)` → `BuildFieldInventory` → (`reconcile: true`) `ReconcileFields` with `apply.field_list`; `persist!(fields:)`; trace `fields_discovered`; step_result `{ fields: n }` | SHA256 of match key + captures, schema ids, `Registry.fingerprint`; nil with `reconcile: true` | `ctx.fields = apply.field_list` |
| `FillFields` | `fill` | see Widgets | nil | - |
| `Submit` | `submit` | see Submit and Verify | nil | - |
| `Verify` | `verify` | see Submit and Verify | nil | - |

## Field inventory

`BuildFieldInventory.call(ctx:, snapshot:)` → `[Apply::Field]`, one per control or group of `FormElements`:

- **Controls**: inputs except buttons, `textarea`, `select`, grouped elements and `textbox/combobox/radio/checkbox/switch`
  roles that are not `<button>`; `search_like` and `disabled` elements are skipped. Units: `group_key` (radio / option
  groups), checkboxes sharing a field root (→ `checkbox_group`), else one element.
- **Kind**: schema kind when `platform.field_key(RawField)` matches a `ctx.schema` id, else DOM (`text email tel url number
  textarea select multiselect combobox radio_group option_group checkbox checkbox_group file date range rich_text`). A
  single-choice schema kind (`select combobox autocomplete radio_group option_group`) yields to the DOM's single-choice
  kind: Ashby's Boolean / small ValueSelect becomes `radio_group` or `option_group` as the page draws it.
- **Merge**: schema wins for label, description, required, options, condition (`source: 'schema_api'`); DOM gives widget,
  target, placeholder, max_length, accept and `default_value` (read_value of a `filled` text-like control).
  Without a schema match everything comes from the DOM (`source: 'snapshot'`, id `f_<signature>_<ordinal>`).
- **Target**: the element's target; groups get the field root as `root` (`:required` visibility is judged on it), file
  inputs keep the hidden input as target with the dropzone as root.
- **Identity**: `signature = Apply::Field.signature_for(label:, kind:, option_labels:)`, `ordinal` = position among equal
  signatures (DOM order). Two fields with one id → `Halt(:unexpected_error, detail: 'field id collision')`.
- **Widget**: `Apply::Widget::Registry.find(field)&.key` (nil = no driver; FillFields halts `no_widget_driver` only if it
  must fill it).

`ReconcileFields.call(stored:, fresh:)`: each stored field takes the fresh one with the same id, else the same
`(signature, ordinal)`; the result is the FRESH field (target, widget, DOM state) under the stored id, semantic and
condition — stored targets are never reused. A stored required field with no match → `Halt(:target_not_found, detail: id)`;
optional ones are dropped; unmatched fresh fields are appended (in 3a they are filled only if answered; FillFields halts
`required_field_unfillable` for a required one without an answer).

## Widgets

Thin driver plugins in `app/concepts/apply/widget/`; `Engine::SetFieldValue.call(ctx:, field:, value:)` does the work:
`driver = Registry.for(field).new(ctx:, field:)` → `GuardAction { driver.write(value) }` → `session.settle(driver.settle_kind)`
→ `driver.read` (`Widget::Base::ReadBack(displayed, invalid, error_text)` from `probe(:read_value)`) →
`driver.accepts?(read_back, value)` (default: `!invalid && MatchOption.same?(displayed, expected_display(value))`). Not
accepted → `GuardAction { driver.fallback_write(value) }` (nil = no fallback → the first `Mismatch`) + settle + read again;
still wrong → `Apply::Widget::Mismatch(field:, wanted:, read_back:)`. Every write is read back; there is no FieldRecovery
yet (3b).

`Registry::DRIVERS` (precedence order; `drivers` / `by_key` memoized; `for(field)` → `Halt(:no_widget_driver, detail: kind)`):

| Driver (`key`) | Kinds | Write | Fallback | Read-back / accepted when | settle |
| -------------- | ----- | ----- | -------- | ------------------------- | ------ |
| `FileInput` (`file_input`) | file | `upload(target, path)` (`:attached`: hidden / clipped input) | - | displayed file name == basename | `:file` |
| `AriaCombobox` (`aria_combobox`) | combobox | for `PREFIXES = [10, 4]`: `dom_mark`, click, unless readonly `fill('')` + `type(prefix)`, `press('ArrowDown')`, `wait_for_listbox(since:, timeout: ctx.clamp(5))`, `MatchOption` → click the option; none → `Mismatch` | - | chip / displayed text == matched option label | `:click` |
| `NativeSelect` (`native_select`) | select | `MatchOption` → `select(label:)` of the matched option; none (or several) → `Mismatch` before any select call (Playwright would time out on a missing label) | `select(value:)` of the matched option | selected text == option label | `:key` |
| `OptionGroup` (`option_group`) | radio_group, option_group, checkbox_group | `MatchOption` over the group's choices (from `probe(:snapshot, root)`), click the label / button / `role` option (unpicked ones only for multi) | - | the checked / `aria-pressed` choice names == the wanted labels, not invalid | `:click` |
| `NativeCheck` (`native_check`) | checkbox | `set_checked` on the visible label when there is one, else the input (`:attached`) | - | `checked` == `MatchOption.truthy?(value)` | `:click` |
| `Text` (`text`) | text, email, tel, url, number, textarea, date | `fill`; in the `:submit` scope `fill('')` + `type` (jitter) for values ≤ `TYPE_LIMIT = 300` chars | `fill('')` + `type` | value (squished) == wanted (catches `maxlength` cuts) | `:key` |

**FillFields** (`Stage::FillFields`, key `fill`): copies `apply.cv` into a temp dir (removed in `cleanup`, also on
halt) for `FileRef.cv` answers, then for `platform.fill_order(ctx.fields)` skipping `hidden`: no answer → skip, or
`Halt(:required_field_unfillable, detail: id)` when required; `SetFieldValue`; `Mismatch` → the same halt when required,
else trace `unfilled` and go on. Then `Answer::ReviewRequired` → `Halt(:review)` (pre-claim), and a fresh snapshot
without any `submit_like` element in the form root → `Halt(:wizard_too_long, detail: 'multi-page form')` (no wizard
pages in 3a). step_result `{ filled: n, unfilled: [ids] }`.

Adding a driver: a class under `apply/widget/` with `handles?(field)` and `write`, override `read` /
`expected_display` / `accepts?` / `fallback_write` / `settle_kind` as needed, add it to `Registry::DRIVERS` at its
precedence (`registry_spec` checks every file is listed), and a `:browser` spec on a fixture page asserting the read-back.

## Obstruction

`Engine::GuardAction.call(ctx:, action:)` wraps every widget write: `snapshot_all` + `RunGates(:after_action)` (cookie
banner, visible captcha) first, then `action.call`. `ApplyMate::Client::Browser::Obstructed` (an action timed out on an
element another element covers) → trace `obstructed`, gates again, ONE retry; a second `Obstructed` →
`Halt(:target_obstructed, detail: reason)`. Other errors pass through without a retry. The Runner maps an `Obstructed`
raised outside the guard to `target_obstructed` too.

## Submit and Verify

**`Stage::Submit`** (key `submit`, scope `:submit`), in this order — everything before `ClaimSubmit` may halt with the
claim untouched:

1. `ctx.remaining < SUBMIT_RESERVE = 120` s → `Halt(:deadline)` (Verify needs up to `EVIDENCE_WAIT` plus a settle).
2. Fresh `FormElements.snapshot` → `RunGates(:before_submit)` (visible captcha → `manual_apply_required`).
3. The ONE visible, enabled `submit_like` element of the form root; 0 or > 1 → `Halt(:target_not_found)`.
4. `GuardAction` around `session.trial_click(button)` (actionability only, no click): an overlay that would swallow
   the click halts as `target_obstructed` with the claim untouched.
5. `session.network_watch(success_evidence[:submit_request][:url])` — registered BEFORE the click, so NetTracker reads
   the response body.
6. `CaptureArtifact(:before_submit)` (never raises) → `ClaimSubmit` → `ctx.scratch.claim_mark = session.network_mark`
   → `session.click` → `settle(:submit)` → `RunGates(:after_submit)` on a fresh snapshot.

**`Stage::Verify`** (key `verify`) → `Engine::VerifySubmit.call(ctx:)` → `Verdict(status, evidence)`:

- **Wait**: one `session.wait_until(timeout: ctx.clamp(EVIDENCE_WAIT = 20))` re-collects the evidence (without field
  probes) until the deterministic signals reach `min_signals`. Needed because a page may send its request well after
  the click (reCAPTCHA token first; ~1.2 s on the fixture), past `settle(:submit)`'s quiet window. Then one full
  `CollectSubmitEvidence`.
- **Evidence** (`CollectSubmitEvidence::Evidence(text, urls, requests, in_flight, form_present, field_errors)`): the visible text
  (text nodes joined by spaces, no script / style) of the form root, or of the frame's body when the root is gone
  (≤ `TEXT_LIMIT = 4_000`); `current_url` + frame URLs; `network_since(claim_mark, bodies: true)`; `in_flight` = `network_in_flight(claim_mark)`; `form_present` =
  the root still holds controls; `field_errors` = `read_value` `invalid` / `error_text` of up to `MAX_FIELD_PROBES = 50`
  known fields (only when the form is present).
- **Signals**: `success_text` (a `texts` regex in the text), `url_match` (a `url_patterns` regex on a URL),
  `submit_request` (a 2xx request matching the URL regex whose body passes `body_ok.(JSON.parse(body))`; a parse error
  counts as false). AI (`Apply::Ai::Prompt::VerifySubmit` on the `Redact`ed text inside untrusted markers,
  `ResponseSchema::VerifySubmit`, kind `:verify`) is asked only when the deterministic count is > 0 and exactly one
  short of `min_signals`, never for a `browser_backed` integration (GeminiScraping); it counts +1 only with
  `submitted: true`, `confidence >= AI_MIN_CONFIDENCE = 0.8` and its `quote` found in the text. An AI verdict alone
  never counts.
- **Status**: count ≥ `min_signals` → `:submitted` (Verify attaches a masked full-page screenshot to `apply.screenshot`,
  a failing screenshot is traced; Finish completes the run). Else form present + field errors + nothing still in flight since
  the claim + every request since the claim answered 4xx (none at all also qualifies) → `:rejected` → `Halt(:validation_rejected, definitive: true)` (releases the claim). A pending request, a transport failure (`status` nil), a 2xx, 3xx or 5xx may mean the server
  took it, so the claim is kept. Else `:unknown` →
  `Halt(:outcome_unknown)` → `submit_unverified` through the claim rule. Trace `verdict` holds the evidence summary.

## Як додати нову платформу

Design §17, adapted to 3a (no generator yet):

1. **Докази.** Зберегти ланцюжок URL, HTML фреймів і snapshot реальної вакансії (read-only) як фікстури у
   `spec/fixtures/files/apply_engine/<platform>/` і, для `:browser`-спеків, сторінки у
   `spec/support/fixture_site/pages/<platform>/`.
2. **Адаптер.** `app/concepts/apply/platform/foo.rb` (`< Apply::Platform::Base`) з рядками `signal`; додати
   `'Apply::Platform::Foo'` у `Registry::PLATFORMS` (`registry_completeness_spec` падає, якщо забути).
3. **Сигнали.** `host`/`url` (фінальна URL), `frame_src`/`script_src` (embed), `query_param`, `dom`;
   `required_captures`, якщо адаптер будує URL або схему з captures. Позитивний і негативний рядок у
   `spec/concepts/apply/operation/engine/detect_spec.rb`.
4. **Провайдери** (необов'язкові): `canonical_form_url`; `fetch_schema` → операція
   `Apply::Operation::Platform::Foo::FetchSchema` через `GuardedFetch`, що кидає `Apply::Platform::SchemaUnavailable`
   (адаптер ловить, трейсить, повертає nil); `apply_key`. Усі URL будувати з одного `self.origin`, щоб spec-підклас
   міг направити адаптер на FixtureSite.
5. **Хуки:** `form_root_selector`, `excluded_regions`, `field_key` (стабільний між двома рендерами, дорівнює id
   поля схеми), `fill_order`, `answer_hints`, `readiness` (`Readiness.schema_keys` за наявності схеми).
6. **Успіх.** `success_evidence` (тексти, URL-патерни, `submit_request` з `body_ok`); поки мутацію не заміряно,
   `min_signals: 2`.
7. **Throttle.** `throttle <interval>, key: ->(ctx) { "foo:#{tenant}" }`.
8. **Gates.** Нестандартна перешкода → `app/concepts/apply/gate/foo_*.rb` + `extra_gates`.
9. **Spec.** `spec/concepts/apply/platform/foo_spec.rb` з `it_behaves_like 'a platform adapter'`
   (`spec/support/shared_examples/platform_adapter.rb`: `positive_evidence`, `negative_evidence`,
   `expected_captures`, `expected_canonical_form_url`, `schema_response`, `expected_schema_size`,
   `field_key_renders`) — детекція +/−, canonical URL, парсинг схеми, стабільність `field_key`, форма
   `success_evidence`, throttle.
10. **Документація.** Таблиця платформи в цьому файлі в тому ж PR.
11. **Живий smoke.** `apply:smoke[<hashid>,<entry url>]` на реальній вакансії через dev browserd (read-only, див.
    "Smoke survey"): платформа, captures, схема, поля з віджетами. Поки платформа не в реєстрі, Handler::Dou веде її
    legacy-шляхом (до 3b).

## Smoke survey (read-only)

Dev/staging tooling to check a live application form without applying. Point it at a **throwaway** queued apply: the
survey ends it in `cancelled`.

```bash
BROWSERD_URL=http://localhost:9300 bin/rails 'apply:smoke[<apply hashid>,https://dou.ua/goto/vacancy/?id=375494]'
```

`lib/tasks/apply.rake` → `Apply::Operation::SmokeSurvey.call(apply:, entry_url:, out: $stdout)` (`skip_authorize`):
`StartContext` on the given apply (must be startable: queued / waiting_capacity / stale running) →
`Stage::DetectPlatform` (the `entry_url` argument overrides `applies.entry_url` / the vacancy's `external_url`) →
`Stage::FetchSchema` → ONE `Session.open(humanize: false)` lease running `Stage::ReachForm` and, for a known platform
with a form root, `Stage::DiscoverFields`. It prints platform, confidence, probable, captures, HTTP hops, schema
field count, canonical URL, navigation ops, form URL and its frame, the ReachForm time (readiness), any halt (a gate
that fired) and the field table (id, kind, widget, label, required, options count, frame). Finally one
`FencedUpdate` ends the apply in `cancelled` (`stage: nil`, `run_token` rotated) with the engine columns the stages
wrote (`SmokeSurvey::RESTORED_COLUMNS`: platform, platform_match, apply_key, entry_url, landing_url, fields, form_url, navigation)
restored; no `apply_steps` rows are written (the Runner is not involved), `attempt` keeps its +1.

Never back to `queued`: `queued` is an `IN_PROGRESS_STATES` member, so `ReapStale` would find the row after
`STALE_AFTER` (verdict lost -> auto-resume -> `Engine::Enqueue`), or the job `Create` enqueued would start it, and the
full engine would fill and **submit** (default `review_policy: never` + `auto_consent: true` pass `ReviewGate`).
`cancelled` is not startable (`StartContext` refuses it) and the rotated token fences a job already in flight
(`smoke_survey_spec.rb` asserts both). Create a new apply to apply for real.

It never answers, fills or submits: no other stage is referenced (`smoke_survey_spec.rb` asserts no fill/type/select/
check/upload/press call and no `ClaimSubmit`). The run's HTTP client (`ctx.scratch.http`) is
`ApplyMate::Client::ImpersonateHttp::ReadOnly`: every Ruby-side POST raises `RequestError` before curl runs, so the
adapter's `fetch_schema` (for Ashby the `ApiJobPosting` GraphQL POST) is traced `schema_unavailable`, the report shows
`schema api: 0` and the field table comes from the DOM. Network side effects are the GETs of the redirect walk, the
page loads (and whatever the page itself requests on a normal visit) and CookieConsent clicks. No heartbeat runs: a survey takes far less than `Apply::STALE_AFTER`.

## Redactor

`Apply::Operation::Engine::Redact.call(text:, apply: nil, max_length: MAX_LENGTH).model` — the only redactor (failure.detail, step
error_detail, step result / trace through `RedactTree`, artifact HTML). Nil-safe, symbols are stringified, output truncated to `max_length` (default `MAX_LENGTH = 2_000`).

| Category | Result |
|---|---|
| `Cookie:` / `Set-Cookie:` / `Authorization:` lines | line dropped |
| `csrfmiddlewaretoken= csrftoken= sessionid= token= code=` values (also `access_token=`) | `name=[REDACTED]` |
| the apply's `source_profile.session_id`, `user.email` (>= 6 chars) | `{{fact.session_id}}`, `{{fact.email}}` |
| any other email | `{{email}}` |
| phone-like digit runs (`\+?\d[\d\s().-]{8,}\d`) | `{{phone}}` (also hits long ids / dates, on purpose) |

## User operations

The user acts on an apply through five operations (`Apply::Operation::Resume`, `Cancel`, `MarkOutcome`, `ApproveReview` (see "Answers and review"), and `Destroy`). All load the record with `policy_scope(Apply).find`, so another user's apply is a 404, then authorize with `resume?`/`cancel?`/`mark_outcome?`/`approve_review?` (owner only). Each transition is one state-guarded `UPDATE` (`update_all ... WHERE id AND state IN (...)`): 0 rows means a concurrent run, claim or cancel won, and the user gets the `not_allowed` error. After a transition they `touch_user_applies_changed_at!` (navbar counter key), broadcast through `Engine::Broadcast`, and answer with a notice. The controller renders only a flash turbo stream; the cards refresh through the broadcast.

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

Stored files (Apply `cv`/`screenshot`, VacancyCv `cv`, ApplyStep `artifacts`) are never linked through permanent blob URLs. `GET /artifacts/:owner/:id/:name` (`artifact_path(owner:, id: hashid, name:, disposition:)`, owner `apply|vacancy_cv|apply_step`, name `cv|screenshot`, or an attachment id for `apply_step`) runs `Artifact::Operation::Show`, which resolves the record through `policy_scope`, authorizes `show?`, checks the name against the owner table (`OWNERS`; `apply_step` has `names: :artifacts` and `name` is the id of one of the step's attachments) and answers a 5-minute presigned storage URL (`inline`, or `attachment` for `disposition=attachment`). `ArtifactsController` redirects to it with `allow_other_host: true` (minio is another host). Unknown owner/name or a missing attachment is a 404. The design names this `Apply::Operation::ShowArtifact` / `ApplyArtifactsController`; one generic operation was chosen so `VacancyCv` (rendered by the same `CvContent` component) needs no second copy.

## UI

State is the single source for the UI: `StatusPill`/`StatusBadge` map `Apply.states` to `apply.state.<state>` and the
current stage to `apply.stage.<stage>`; `ActionBox` offers Apply / Retry (Resume) / Cancel by state;
`FailureNotice` shows only localized `apply.failure.<code>` and `apply.failure_hint.<code>` (never raw
exceptions); for `needs_human`/`unsupported` it shows the "apply yourself" notice with "Відкрити посилання" and
"Я подався вручну" (MarkOutcome `manual`). `RunTimeline` renders the preloaded `apply_steps` grouped by attempt
(newest open), with each step's artifacts as links (`artifact_path('apply_step', ...)`).
`ReviewForm` (`apply.review.*`, mounted in `VacancyApplyCard` for `needs_review`) lists the `failure.detail` reasons
of a `review` halt (`already_applied`, whose detail is the earlier apply's hashid, shows the `duplicate` reason instead;
`foreign_origin` as an amber alert with the form host; `duplicate` adds the required `confirm_duplicate` checkbox) and one
row per answered or required fillable field with a source chip; it posts `answers[<field_id>]` to `approve_review`.
A multiple select is preceded by a blank `answers[<id>][]` hidden sentinel (deselecting everything posts `[""]`, which
`ApproveReview` turns into a cleared answer); number inputs get `step="any"` (fractions are valid answers); a `date`
field renders `type=date` only for an empty or ISO `YYYY-MM-DD` value, otherwise a text input (a date input would show
and post "" for "June 2025").
It takes `user:` like `FailureNotice` because StatusUpdate broadcasts render it without `current_user`, and `FailureNotice`
hides for code `review` while the form shows. `ActionBox` shows a "Переглянути" link to the card instead. The navbar counter and the "Потребують уваги" filter share `Apply.attention_count_for`.
`spec/i18n/apply_engine_keys_spec.rb` iterates `Halt::CODES`, `Apply.states` and every `Apply::Operation::Base`
stage, so a new code/state/stage without uk and en texts fails the suite (and en must contain no Cyrillic).

## Deviations from the design (phase 1)

- Column subset: only the columns phase 1 needs exist (`state`, `stage`, `attempt`, `run_token`, `heartbeat_at`,
  `deadline_at`, `submit_claimed_at`, `submitted_via`, `failure`, `job_id`, ...); later phases add the rest.
- `Artifact::Operation::Show` is generic (Apply and VacancyCv) instead of `Apply::Operation::ShowArtifact`.
- The 48 h reminder is in-app only (card notice + navbar counter); no e-mail/push channel exists yet.
- Legacy data writes (`inputs`, `filled_inputs`, `cv`, `apply_type`, ...) by the legacy steps are not fenced until
  phase 4; only lifecycle writes go through `FencedUpdate`.
- `RunTimeline` shows the step rows with links to their failure artifacts (see "Failure artifacts").

## Deviations from the design (phase 3a)

- **No Transport classes** (design §5): each platform's HTTP reads go through the run's `ctx.http`
  (`ImpersonateHttp`, `GuardedFetch` with `--resolve` pinning) inside the adapter's `fetch_schema`; the browser side is
  the scope's `Session`. `Platform::Base` has no `transport` DSL.
- **Failure artifacts are an operation** (`Engine::CaptureArtifact`, called by the Runner on a failed step and by
  `Stage::Submit` before the click), not a middleware around every step.
- **`users.auto_consent`** (boolean, default true per §18) instead of the design's `auto_consent_required` naming.
- **No settings UI for `users.review_policy` / `users.auto_consent` yet** (design §15 row 3a lists none): both keep
  their §18 defaults (`never`, `true`) and change only from the console, so the `policy_always`, `unknown_platform`
  and `consent_pending` review reasons (and their locale texts) are reachable only that way until a settings screen
  exists. The safety reasons do not depend on either column.
- **No AiBudget and no recipe learning yet**: `StartContext` does not reset an `ai_calls` counter; `Apply::Recipe::Op`
  holds only the `goto` / `unwrap` ops that `applies.navigation` stores, and a stored navigation is not replayed
  (the submit scope re-reaches the form the same way; replay arrives in 3b, learning in phase 6).
- **The CV stage is `Ai::GeneratePdfCv`**, reused unchanged (key `generate_cv`, no input digest: it re-runs on a
  resumed attempt).
- **`Apply::Handler::Djinni` untouched** (phase 4); Handler::Dou keeps the legacy external path for platforms the
  registry does not know until the Navigator (3b).
- `Apply::Field` is `class Apply::Field < Data.define(...)` (constants inside a `Data.define` block would land on
  Object).
- `FixtureAshby` (spec) keeps the key `ashby` instead of `fixture_ashby`: schema ids (`ashby:<path>`) and
  `Context#schema_keys` derive from the key; only `origin` (and the signals built from it) is overridden.
- `ResolvePublicAddress` pins the first IPv4 answer (else the first answer): an IPv6 pin on an IPv4-only host made
  every pinned fetch fail. All answers are still checked public.
- Stage restores read the unredacted `applies.platform_match` / `applies.landing_url` / `applies.form_url`: stored step results go through
  `RedactTree`, whose phone rule rewrites UUID digit runs.

## Specs

- `engine_context(apply)` (`spec/support/apply_engine.rb`) is a real `StartContext`; `rotate_run_token!(apply)`
  simulates a newer run (zombie).
- `spec/support/apply_engine_fakes.rb`: `ApplyEngineFakes::PrepareStep` (`stage :fake_prepare`),
  `ApplyEngineFakes::SubmitStep` (`stage :fake_submit`), `ApplyEngineFakes::Handler`, the digest-aware stages
  `DigestOne` / `DigestTwo` (class-level `digest` / `restored` / `observe` to stub) and `ScopedHandler` (a scope-less
  step, a `:survey` scope of both digest stages, a `:submit` scope; wrap with `stub_browser_session(FakeSession.new(...))`). Stub the step's
  `observe(ctx, **options)` to look at the run mid-step or to raise / claim.
- Engine specs live in `spec/concepts/apply/operation/engine/`. Stub `Apply::TurboHandler::StatusUpdate.broadcast`;
  use `type: :job` where `have_enqueued_job` is asserted (auto-resume, Enqueue).
- `spec/concepts/apply/job/apply_e2e_spec.rb` runs Job -> Handler -> Runner on the honeytech DOU context (claim,
  step rows, idempotent re-run, zombie writes nothing, `job_id` stored by `Enqueue`).
- `spec/concepts/apply/handler/dou_ashby_browser_spec.rb` (`:browser`) runs Job -> Handler::Dou -> Runner on the real
  browserd-test against FixtureSite's Ashby pages (`FixtureAshby`, `stub_fixture_ashby_registry`,
  `FixtureSite.on_submit`; `rspec.md`): full run with one POST and the claim before it, the `review_policy: always`
  resume, and the Google Forms redirect (`needs_human`, no lease). `dou_spec.rb` covers the routing without a browser
  (known / unknown / internal, step-key uniqueness).
- `spec/concepts/apply/operation/smoke_survey_spec.rb`: SmokeSurvey on a FakeSession (report, no fill/claim, apply
  restored to queued, Google Forms halt without a lease).
