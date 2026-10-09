# Apply Engine

How an `Apply` runs: lifecycle states, why a run stops (`Halt` codes), the submit claim, `run_token` fencing, the
heartbeat and the Runner. Read before touching `Apply` state, `Apply::Operation::Engine::*` or `Apply::Job::*`.
Handler/step authoring is in `apply_handlers.md`.

## Contents

- [Operations, not POROs](#operations-not-poros) · [Lifecycle states](#lifecycle-states) · [Halt](#halt) ·
  [Claim rule](#claim-rule) · [Fencing](#fencing) · [StartContext and timing](#startcontext-and-timing) ·
  [Heartbeat](#heartbeat) · [AI budget (CallAi)](#ai-budget-callai)
- [Runner](#runner) (failure artifacts, host slots, internal-path steps) ·
  [Recurring jobs](#recurring-jobs-general-queue) (reaper, ExpireWaiting, pruning)
- Engine data: [Apply::Field](#applyfield) (engine columns, profile facts) · [Context scratch](#context-scratch)
- Engine pipeline: [Handler::Dou routing](#handlerdou-routing) · [Stages](#stages) ·
  [Platform adapters (DSL)](#platform-adapters-dsl) · [Detection](#detection) · [Gates](#gates) ([awaiting input](#awaiting-input-emailcode)) ·
  [DetectPlatform, FetchSchema](#stages-detectplatform-fetchschema) · [Answers and review](#answers-and-review) ·
  [Snapshot and form elements](#snapshot-and-form-elements) · [Reach form](#reach-form) ·
  [Navigator (Generic)](#navigator-generic) · [Field inventory](#field-inventory) · [Widgets](#widgets) ([field recovery](#field-recovery)) · [Obstruction](#obstruction) ·
  [Submit and Verify](#submit-and-verify) · [Як додати нову платформу](#як-додати-нову-платформу) ·
  [Smoke survey](#smoke-survey-read-only)
- [Redactor](#redactor) · [User operations](#user-operations) · [Create guards](#create-guards) ·
  [Attention inbox](#attention-inbox) · [Artifacts](#artifacts) · [UI](#ui)
- Deviations: [phase 1](#deviations-from-the-design-phase-1) · [phase 3a](#deviations-from-the-design-phase-3a) ·
  [phase 3b](#deviations-from-the-design-phase-3b) · [Specs](#specs)

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
| `capture_artifact.rb` | `CaptureArtifact`: masked screenshot / sanitized + redacted HTML of the open session onto a step row |
| `sanitize_html.rb` | `SanitizeHtml`: the one sanitizer for stored page HTML (no scripts / frames / handlers, CSP meta) |
| `redact_tree.rb` | `RedactTree`: `Redact` over every string leaf of a hash / array (step `result` and `trace`) |
| `reap_stale.rb`, `expire_waiting.rb`, `prune_apply_steps.rb` | recurring sweeps (see below); jobs in `app/concepts/apply/job/` only call them |
| `reach_form.rb`, `wait_ready.rb` | `ReachForm` (stored-navigation replay / landing / canonical unwrap / navigation recipe / current page / the Navigator → form root), `WaitReady` (readiness poll over frames) |
| `navigate.rb` | `Navigate`: the Generic AI Navigator (design `Engine::Navigator`; its `Guard` / `Budget` are private state), `Navigate::Decision` value; model = the op hashes performed, ending with `wait_for` |
| `execute_action.rb` | `ExecuteAction`: validates and performs ONE Navigator action as a recipe op (design `Engine::Executor`) |
| `assess_form_likeness.rb` | `AssessFormLikeness`: rule R2 "is this an application form?" (design `Engine::FormLikeness`), `AssessFormLikeness::Verdict` value; Navigate, `Recipe::Interpret#verify_form!`, `Stage::DiscoverFields` (Generic) |
| `adopt_new_tab.rb` | `AdoptNewTab`: the one new-tab rule (`AdoptNewTab.watch(ctx, target)` before the action, `.call(ctx:, pages_before:, expect_tab:)` after); `Recipe::Interpret` and `ExecuteAction` |
| `observe.rb` | `Observe`: one rendered look after a navigation or action (`snapshot_all` → `RunGates(event)` → `CollectRenderedEvidence` → `ctx.redetect!`), model = the match; `Recipe::Interpret` and `ReachForm`'s landing poll |
| `form_elements.rb` | `FormElements`: the snapshot elements inside `ctx.form_root` (frame + region), minus `excluded_regions` |
| `build_field_inventory.rb`, `reconcile_fields.rb` | `BuildFieldInventory` (snapshot + schema → `[Apply::Field]`), `ReconcileFields` (stored ↔ fresh) |
| `set_field_value.rb`, `guard_action.rb` | `SetFieldValue` (widget write + read-back + one fallback; `result[:approximate]`), `GuardAction` (obstruction guard) |
| `classify_advance.rb` | `ClassifyAdvance`: the ONE submit / Next locator (design `Engine::SubmitLocator.classify`), `ClassifyAdvance::Advance(kind, target, name)` value, `kind` `:next` / `:final`; `Stage::FillFields` (wizard loop) and `Stage::Submit` |
| `answer_followups.rb` | `AnswerFollowups`: a wizard page after a Next click (design `ctx.answer_followups!`): fresh inventory, `ReconcileFields(strict: false)`, ONE `Answer::Resolve(fields:)` call for the new fields (capped); model = the page's fields |
| `recover_field.rb` | `RecoverField`: field recovery after a `Widget::Mismatch` (design `Engine::FieldRecovery`, §7.3 O7): ≤ 2 AI click / press micro-turns, then `SetFieldValue` again |
| `await_input.rb` | `AwaitInput`: parks the run for a code the user types (Gate::EmailCode; see [Awaiting input](#awaiting-input-emailcode)) |
| `call_ai.rb` | `CallAi`: the only door to the AI inside the engine (SQL-side budget, latency-aware timeout clamp, token accounting; `CallAi.allowance`) |
| `check_origin.rb` | `CheckOrigin`: is the form on a site the vacancy led to? (the one `foreign_origin` rule; `ReviewReasons` and the Navigator call it) |
| `collect_submit_evidence.rb`, `verify_submit.rb`, `submit_baseline.rb` | `CollectSubmitEvidence` (`Evidence` value), `VerifySubmit` (`Verdict` value; `VerifySubmit.page_signals`), `SubmitBaseline` (page signals before the click) |

| File (`app/concepts/apply/operation/recipe/`) | What it is |
|---|---|
| `interpret.rb` | `Interpret.call(ctx:, ops:)`: runs a recipe (op hashes or op objects), follows new tabs, observes after every op; model = the performed op hashes (see Reach form) |
| `drift.rb` | `Drift < StandardError` (`op`, `detail`, `performed` = the op hashes run before it): a recipe op no longer works on the page; rescued by `Engine::ReachForm`, never a Halt |

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
| needs_human | needs_human | `captcha_challenge email_code missing_profile_fact session_expired manual_apply_required ai_quota_exhausted` |
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
| `ApplyMate::Client::LocalChrome::Busy` | `capacity`, but NOT `waiting_capacity`: a transient halt through `RecordHalt` → one auto-resume (before the claim), the second one stays `failed(:capacity)` (the process-wide local Chrome slot stayed taken: GeminiScraping, the Grover CV render; see [Latency-aware budgets](#latency-aware-budgets-and-the-local-chrome-slot)) |
| `ApplyMate::Ai::Client::Base::Unavailable` | `capacity` (transient, one auto-resume before the claim): the AI provider answered 429 / 5xx / timed out (overload, per-minute rate limit) after `CallAi`'s bounded retries (`TRANSIENT_RETRIES = 2`, deadline-clamped backoff). `Client::Gemini#with_retries` raises it with the message scrubbed (`Client::Base.scrub`) and `cause: nil`; `SmokeSurvey` reports it as its halt line |
| `ApplyMate::Ai::Client::Base::QuotaExhausted` | `ai_quota_exhausted` (needs_human, never retried): the provider's quota is used up for hours (Gemini: a `PerDay` quotaId in the 429 body, or `retryDelay` >= `QUOTA_RETRY_DELAY = 3_600` s). The user retries later (Resume) or cancels and applies again with another integration |
| any other `ApplyMate::Ai::Client::Base::ProviderError` (e.g. a Gemini 400) | `unexpected_error`; message `"<Faraday class>: <scrubbed message + body excerpt>"`, no cause chain |
| `ApplyMate::Ai::Client::Base::DeadlineTooShort` | `deadline` (transient): the AI call's timeout was shorter than the client can start in (GeminiScraping: < `SETUP_SECONDS`), i.e. the run is out of time, nothing is contended |
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
       deadline_at = now() + run_seconds, heartbeat_at = now(), stage = NULL, ai_calls = 0,
       input_request = NULL, input_response = NULL, updated_at = now()
 WHERE id = $1
   AND (state IN (0, 2) OR (state = 1 AND COALESCE(heartbeat_at, updated_at) < now() - STALE_AFTER))
RETURNING attempt, run_token, deadline_at
```

`run_seconds = StartContext.run_seconds(apply.ai_integration)` = `RUN_DEADLINE` + `CallAi.allowance(integration,
Context::RUN_AI_CALLS = 8)`: 30 min with an API integration, 30 + 8 × 180 s = 54 min with GeminiScraping
(`StartContext.max_run_seconds` is the largest over all providers, 54 min).

0 rows → `NotStartable`: a second job never starts on top of a live run; a job redelivered after a crash starts
once the old heartbeat is stale. After a start, `CloseSteps` fails step rows of earlier attempts still `running`. `failure` is kept across starts (it carries `auto_resumed`). `ai_calls = 0` resets the per-attempt AI budget
(see [AI budget](#ai-budget-callai)); `ai_calls_total` is never reset. `input_request` / `input_response` are cleared too, so a resumed run never consumes a stale
code (see [Awaiting input](#awaiting-input-emailcode)).

| Constant (`Apply::`) | Value | Used by |
|---|---|---|
| `RUN_DEADLINE` | 30 min | `StartContext` (`deadline_at = now + run_seconds`, i.e. `RUN_DEADLINE` + the slow-AI allowance: 30 min API, 54 min GeminiScraping); the Runner raises `Halt(:deadline)` before a step once `ctx.remaining <= 0` |
| `STALE_AFTER` | 3 min | `StartContext` takeover of a `running` row; `ReapStale` candidates |
| `SCOPE_DEADLINE` (`Context::`) | 8 min | `Context#scope_deadline` = `min(now + SCOPE_DEADLINE + ai_allowance(SCOPE_AI_CALLS = 4), deadline_at)`: 8 min API, 8 + 4 × 180 s = 20 min GeminiScraping; passed to `Session.open(deadline:)`, which asks browserd for `ttl_s = deadline - now + 60 s` (≤ 21 min, within `LEASE_TTL_S = 1800`, the maximum) and cuts its own deadline to `expires_at - 60 s` |
| `HEARTBEAT_GRACE` | 5 min | `Heartbeat::Tick` stops beating after `deadline_at + HEARTBEAT_GRACE` |
| `REAPER_GRACE` | 15 min | `ReapStale`: a live process is trusted until `deadline_at + REAPER_GRACE` |
| `HUMAN_TIMEOUT` | 7 days | `ExpireWaiting` (`WAIT_TIMEOUTS['needs_human']`), `Apply#wait_expires_at` |
| `REVIEW_TIMEOUT` | 72 h | `ExpireWaiting` (`WAIT_TIMEOUTS['needs_review']`), `Apply#wait_expires_at` |
| `REMIND_AFTER` | 48 h | `ExpireWaiting` reminder (`REMINDER_DUE_SQL`, `index_applies_remind_candidates`) |

`Apply::Job::Apply` runs on queue `apply` with `limits_concurrency to: 1, key: "apply:<id>", duration:
StartContext.max_run_seconds.seconds + CONCURRENCY_SLACK` = 54 + 15 = 69 min: longer than the longest run plus
`HEARTBEAT_GRACE` (54 + 5 min), after which a run cannot own its row anyway. Ownership for
the whole run is enforced by `run_token` + heartbeat, not by the concurrency window.

## AI budget (CallAi)

Every AI call of the engine goes through `Apply::Operation::Engine::CallAi.call(ctx:, prompt:, schema:, requires: [],
images: [], system: nil).model` (the parsed `schema.extract` data, indifferent access); `AiHandler.call` stays only for
the non-engine callers (`VacancyCv`, `VacancyQuestion`, `ExtractFacts`, `GeneratePdfCv`). Sequence:

1. `ctx.check_fence!`.
2. No capability is required (owner decision 2026-10-09: the apply system is universal). A client without native
   `:json_schema` runs in text mode (format instructions + `ResponseSchema::Json` parsing), a `browser_backed` one
   (GeminiScraping) may run inside a lease. Images without `:vision` are dropped (trace `ai_images_dropped`), never an
   error.
3. ONE statement counts the call: `UPDATE applies SET ai_calls = ai_calls + 1, ai_calls_total = ai_calls_total + 1,
   updated_at = now() WHERE id = $1 AND run_token = $2 RETURNING ai_calls, ai_calls_total` (primary key; SQL-side
   because the heartbeat thread and fibers write the same row). 0 rows = `ctx.fence!` + `Fenced`.
   `ai_calls_total > 90` is `Halt(:ai_lifetime_cap)` (checked first), `ai_calls > 30` is `Halt(:ai_budget_exhausted)`.
4. `timeout = min(client.call_seconds(kind), the caller's own cap, floor(ctx.remaining - 30))`; below 5 s is
   `Halt(:deadline)`. `call_seconds(kind)` is the client's declared latency (`Client::Base.call_seconds`, the one
   latency declaration): the kind's `Request::TIMEOUTS` for an API, `GeminiScraping::CALL_SECONDS` = 240 s. Recomputed
   before every try.
5. `AiHandler.complete` with client `retries: 0`: `CallAi` owns the retry, inside a lease and outside. A transient
   `Client::Base::Unavailable` (429 rate limit, 5xx, timeout) is retried at most `TRANSIENT_RETRIES = 2` times after
   `RETRY_BACKOFF * 2**(n-1)` s (2 s, 4 s), clamped to `floor(ctx.remaining - AI_RESERVE - MIN_TIMEOUT)`; with no room
   left or the retries spent, `Unavailable` propagates (Runner: `capacity`). What stops it when the provider stays
   down: the retry count and the deadline. Each retry is traced `ai_retry` (`attempt`, `wait`, scrubbed `error`),
   re-checks the fence after the sleep, and is NOT re-counted in the AI budget (same call). `QuotaExhausted` is never
   retried (Runner: `ai_quota_exhausted`).
6. the tokens are added SQL-side (`col = col + n`) to `applies.ai_input_tokens/ai_output_tokens` and to
   `ctx.scratch.step_record` (a provider that reports none counts 0); trace `ai_call`. A schema-invalid answer is
   accounted too before `InvalidResponse` propagates (`AiHandler` sets `InvalidResponse#usage`; traced with
   `invalid: true`).

`InvalidResponse` / `EmptyResponse` propagate: the caller decides about its single retry, the Runner maps what is left.

| Constant (`CallAi::`) | Value |
|---|---|
| `MAX_AI_CALLS_PER_ATTEMPT` | 30 |
| `MAX_AI_CALLS_PER_APPLY` | 90 |
| `AI_RESERVE` | 30 s kept for the step after the call |
| `MIN_TIMEOUT` | 5 s |
| `TRANSIENT_RETRIES` | 2 (retries of `Unavailable`) |
| `RETRY_BACKOFF` | 2 s, doubled per retry, clamped to the deadline |

### Latency-aware budgets and the local Chrome slot

`CallAi.allowance(ai_integration, calls)` is the one sizing rule: `calls * slowdown`, slowdown = what one call of the
client takes beyond the fast default (0 for an API, 180 s for GeminiScraping). `StartContext.run_seconds` adds the
allowance of `Context::RUN_AI_CALLS` calls to `Apply::RUN_DEADLINE`, `Context#scope_deadline` adds that of
`SCOPE_AI_CALLS`, the Navigator adds that of `SCOPE_AI_CALLS` and field recovery that of its `MAX_TURNS`, and `Session.open` asks browserd for a
lease of `deadline - now + 60 s` (`POST /leases {ttl_s}`, clamped by browserd's `LEASE_TTL_S`, see browser.md). A slow
AI therefore never kills the lease or the scope mid-run; every wait keeps a deadline.

Resource model: `APPLY_SLOTS` Camoufox leases (3 on the Pi 5, in browserd) plus AT MOST ONE local Chrome per apply
worker process. `ApplyMate::Client::LocalChrome::SLOT` is a process-wide `Concurrent::Semaphore(1)` held by both
things that launch one in the worker: a GeminiScraping call and the Grover PDF render of
`Apply::Ai::ResponseSchema::GenerateCv` (the CV step of every apply, `VacancyCv::Job::Create`). Every wait terminates:

- GeminiScraping waits only while its own `Request#timeout` still leaves `SETUP_SECONDS` (60 s), then raises
  `LocalChrome::Busy` (Runner: `capacity`, transient, one auto-resume; the AI jobs retry it 3×). A timeout already
  shorter than `SETUP_SECONDS` raises `Client::Base::DeadlineTooShort` at once (Runner: `deadline`).
- The Grover render waits `GenerateCv::RENDER_SLOT_WAIT` = `CALL_SECONDS + 60` = 300 s (one full GeminiScraping call
  plus one other render), then `LocalChrome::Busy`; the render itself is capped at `RENDER_TIMEOUT_MS = 60_000`.

Fit on the Pi 5 (16 GB, 4 cores), ESTIMATES: browserd is capped at 6 GB / 3 cores for 3 Camoufox; the apply worker at
3 GB holds Rails with 3 job threads (about 0.5–0.7 GB) plus the one local Chrome (GeminiScraping about 0.6–1 GB, a
Grover render about 0.2–0.4 GB), peak ≈ 1.7 GB. Without the shared slot, one GeminiScraping Chrome + two concurrent
Grover renders (≈ 2.5 GB with Rails) would sit at the 3 GB OOM line. The 4 cores, not RAM, are the limit. Full
breakdown: browser.md "Staging".

`Stage::AnswerFields` still raises if a scope is open (the answers are asked before the lease); `VerifySubmit`
corroboration may use any client and lets a `Halt`/`Fenced` of `CallAi` through.

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
and, for `:failure`, the HTML of each frame (`SanitizeHtml`, then `Redact` with `max_length: HTML_LIMIT = 512 KB`) as
`<label>_f<i>.html` to `step_record.artifacts`. `Engine::SanitizeHtml.call(html:)` is the ONE implementation for any
stored page HTML (opening a snapshot must never run the page: Ashby's SPA reloaded itself forever): it removes
`script` (any namespace), `noscript`, `iframe`, `frame`, `frameset`, `object`, `embed`, `applet`, `base`, `portal`,
`<meta http-equiv=refresh>`, every `on*` attribute and every `javascript:` / `vbscript:` attribute value, and puts
`<meta http-equiv="Content-Security-Policy" content="SanitizeHtml::CSP">` (`default-src 'none'; img-src data: https:;
style-src 'unsafe-inline' https:; font-src https: data:`) first in `<head>`. Text and other markup are kept. It never raises (logged + `Rails.error`): evidence must not replace the error being
recorded. Access: `GET /artifacts/apply_step/:step_hashid/:position` runs `Artifact::Operation::Show` (owner
`apply_step`, `names: :artifact_at`: the 1-based position in `ApplyStep#ordered_artifacts`, attach order, never the
global attachment id; `ApplyStepPolicy` delegating to `ApplyPolicy`, `policy_scope` joins `applies` by
user); an HTML artifact (`Show::DOWNLOAD_ONLY`: text/html, application/xhtml+xml) is always served with
`disposition: attachment`, whatever was asked; `RunTimelineAttempt` lists the links. `PruneApplySteps` purges them after `ARTIFACT_RETENTION`.

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

### Internal-path steps (until phase 4)

The pre-engine steps of the internal (in-platform, HTTP) apply path run under the Runner unchanged in their HTTP / AI
behaviour; only the state plumbing moved (details and the submit table in `apply_handlers.md`). Every external apply
runs the engine stages ("Stages").

| Stage key | Steps | Halt codes they raise |
|---|---|---|
| `check_applyable` | `CheckApplyable` | `no_application_path` |
| `fetch_apply_type` | `FetchApplyType` | `no_application_path` |
| `fetch_details` | `FetchDetails` (Djinni) | — |
| `fetch_form` | `FetchInternalForm` | `not_a_form` |
| `fill_form` | `Ai::FillForm` | `invalid_ai_output` |
| `generate_cv` | `Ai::GeneratePdfCv` | — (`Apply.with_cv_or_generating_cv` keys on this string) |
| `submit` | `SendApply::Http` | `outcome_unknown`, `session_expired` (definitive) |

- Steps raise through `Apply::Operation::Base#halt!(code, detail:, definitive:)`.
- Claim placement: `SendApply::Http` claims after building the payload, right before `post_multipart`.
- Only `SendApply::Http`'s login redirect is definitive (releases the claim → `needs_human`).
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
| `prefix` | snapshot.js `prefix`: the fixed letterless text just before a text input (Hurma's `<span>+380</span><input type=tel>`, a `$`); `nil` for schema-only fields. `Answer::CoerceValue` types an international value after a dial-code prefix (`DIAL_CODE` `+` 1-4 digits) without that code (`+380 67 123 45 67` → `671234567`); a national value or another country's code stays as given |
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

### Engine columns (phase 3a, 3b)

| Table | Columns |
| ----- | ------- |
| `applies` | `platform`, `platform_match` (jsonb), `apply_key` (`index_applies_on_user_apply_key`, partial `apply_key IS NOT NULL`: the already-applied check), `entry_url`, `form_url`, `navigation` (jsonb), `fields` (jsonb), `answers` (jsonb), `answers_approved_digest`, `reviewed_at`, `duplicate_confirmed_at`, `ai_calls` (this attempt, reset by `StartContext`), `ai_calls_total` (the apply's life), `ai_input_tokens` / `ai_output_tokens` (bigint, life totals), `input_request` / `input_response` (jsonb, the awaiting-input handshake) |
| `apply_steps` | `scope`, `input_digest`, `trace` (jsonb), `ai_input_tokens` / `ai_output_tokens` (integer, the step's share), `artifacts` (Active Storage, at most `ApplyStep::MAX_ARTIFACTS_PER_ATTEMPT = 8`); partial `index_apply_steps_resume_lookup (apply_id, key, input_digest) WHERE state = 1` (keyed by `key`, not `stage`: one stage runs in two scopes) and `index_apply_steps_prunable_trace` |
| `apply_host_slots` | `host_key` (primary key), `next_allowed_at` (per-tenant throttle), `holder_apply_id` (the apply that took it; no index or FK, read through the primary-key row only) |
| `user_profiles` | `facts` (jsonb `{ 'ai' => {...}, 'user' => {...} }`), `facts_cv_digest` (SHA256 of the CV the facts came from) |
| `users` | `review_policy` (enum `always 0`, `unknown_platforms 1`, `never 2`; default `never`), `auto_consent` (boolean, default `true`) |

### Profile facts

`UserProfile::Operation::ExtractFacts` makes one AI call and stores the result under `facts['ai']`. Two callers: the job `UserProfile::Job::ExtractFacts` (queue `:apply`, enqueued by profile Create/Update when `saved_change_to_cv?`; the user's default AI integration, none -> facts stay `nil`; `retry_on` `EmptyResponse` / `InvalidResponse` / `GeminiScraping::ResponseTimeoutError` / `Client::Base::Unavailable` / `Faraday::Error`, 3 attempts, `polynomially_longer`) and `Stage::AnswerFields` (inline before `Answer::Resolve`, with `apply.ai_integration`), so a profile whose facts were never extracted (created before the column, saved without an integration, a job out of retries) gets them at its next apply: no absorbing "facts nil" state. It returns early while `facts_cv_digest` equals the CV digest. A re-extraction replaces only `facts['ai']`; `facts['user']` is kept and `UserProfile#fact(key)` returns the user value before the AI value.

## Context scratch

`Context` members are immutable; what the stages learn during ONE run lives in `ctx.scratch`
(`Context::Scratch` Struct: `session scope scope_deadline platform match evidence schema fields form_root form_url
trace platform_switches claim_mark artifacts_count consent_clicks http canonical_unwrapped step_record
submit_baseline followup_calls wizard_page`, built by
`Scratch.fresh` in `Context#initialize`, so every `StartContext` run starts empty), shared by copies made with `#with`
and never persisted as a whole. `followup_calls` (starts 0) counts the wizard pages that brought new fields in this run
(`Engine::AnswerFollowups`, capped at `MAX_FOLLOWUP_ANSWER_CALLS`). `wizard_page` (starts 1) is the wizard page the
submit scope is on, advanced by `Stage::FillFields` right after each Next click; `Engine::ClassifyAdvance` uses it to
tell a stored follow-up field still ahead (a replay after an approved review) from one already behind. Helpers:

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
engine! if: ->(ctx) { ctx.apply.external? }
add_step Apply::Operation::FetchInternalForm, if: ->(ctx) { ctx.apply.internal? }
add_step Apply::Operation::Ai::FillForm,      if: ->(ctx) { ctx.apply.internal? }, ...
add_step Apply::Operation::Ai::GeneratePdfCv, if: ->(ctx) { ctx.apply.internal? }, ...
add_step Apply::Operation::SendApply::Http,   if: ->(ctx) { ctx.apply.internal? }
```

- **External** (every one, whatever the platform and whatever AI integration the user chose): `detect`, then the
  engine stages below. A known platform (Ashby) is reached by its adapter (canonical URL / schema; a probable known
  platform such as Preply's `?ashby_jid=` is identified on the rendered landing page by ReachForm); anything else
  stays `generic` and is reached by the [Navigator](#navigator-generic) inside `navigate:survey`. Steps keys:
  `check_applyable fetch_apply_type detect schema [navigate:survey discover:survey] answer generate_cv review throttle
  navigate:replay:submit discover:submit fill:submit submit:submit verify:submit` (the `:survey` scope only while
  `ctx.survey_needed?`).
- **Internal**: `check_applyable fetch_apply_type fetch_form fill_form generate_cv submit` over HTTP (until phase 4).
- `generate_cv` is declared twice (engine! and the internal list) with mutually exclusive conditions; `apply_steps`
  is unique on `(apply_id, attempt, key)`, and `dou_spec.rb` ("step conditions") asserts for both apply types that no
  two active steps share a key and exactly one `generate_cv` runs.
- `Apply::Handler::Djinni` is unchanged (phase 4).

## Stages

Declared by `Handler::Base.engine!` (`apply_handlers.md`, "Session scopes and `engine!`"), in run order. "Digest":
the step is skipped with `restore` when a succeeded row with the same key and `input_digest` exists (Runner);
"always" = no digest. Scopes are atomic units with one lease each (`humanize: true` only for `:submit`).

| Key | Stage | Scope | Digest (input) | Halts |
|---|---|---|---|---|
| `detect` | `Stage::DetectPlatform` | — | entry URL + `Registry.fingerprint` | `no_application_path` (no entry URL, > `MAX_HOPS` redirects), `already_applied`, http gates (`manual_apply_required`/`google_forms`, `external_messenger`, `login_required`, `bot_wall`, `private_address`) |
| `schema` | `Stage::FetchSchema` | — | match key + captures | — (`SchemaUnavailable` → no schema, DOM fallback) |
| `navigate:survey` | `Stage::ReachForm` | `:survey` (only while `ctx.survey_needed?`) | match key + captures + schema ids | `not_a_form`, `already_applied` (after a platform switch), rendered gates (`manual_apply_required`/`captcha`, `login_required`, `bot_wall`, `closed_posting`, `email_code`, ...); the Navigator's `stuck`, `budget_exhausted`, `deadline`, `invalid_ai_output`, `ai_budget_exhausted` and its `give_up` codes (`Navigate::GIVE_UP_CODES`; `captcha_challenge` → `manual_apply_required`) |
| `discover:survey` | `Stage::DiscoverFields` | `:survey` | match + schema ids + `Registry.fingerprint` | after_goto gates, `not_a_form` (Generic: the inventory fails R2) |
| `answer` | `Stage::AnswerFields` | — | field list, CV digest, `facts['user']`, name, email, `auto_consent`, prompt template + id | `invalid_ai_output` (Runner mapping) |
| `generate_cv` | `Ai::GeneratePdfCv` | — | always | — |
| `review` | `Stage::ReviewGate` | — | always | `review` (→ `needs_review`) |
| `throttle` | `Stage::AcquireHostSlot` | — | always | none; raises `Engine::Throttled` (→ `waiting_capacity`, retried by `Job::Apply` up to `MAX_THROTTLE_WAITS`, then `capacity`) |
| `navigate:replay:submit` | `Stage::ReachForm replay: true` | `:submit` | always | `not_a_form`; after a `recipe_drift` the Navigator's halts (heal mode) |
| `discover:submit` | `Stage::DiscoverFields reconcile: true` | `:submit` | always | after_goto gates |
| `fill:submit` | `Stage::FillFields` | `:submit` | always | `required_field_unfillable` (after `RecoverField`), `review` (before any Next click and before the claim), `validation_rejected` (a Next click that leaves the page key unchanged), `wizard_too_long` (> `MAX_WIZARD_PAGES` = 6 pages, > `MAX_FOLLOWUP_ANSWER_CALLS` = 8 follow-up answer calls), `target_not_found` (no submit or Next button; a stored required later-page field never shown), `no_widget_driver`, `target_obstructed`, after_action gates on a new page |
| `submit:submit` | `Stage::Submit` | `:submit` | always | before the claim: `deadline` (< `SUBMIT_RESERVE` = 120 s left), before-submit gates, `target_not_found` (no or ambiguous button), `wizard_too_long` (`ClassifyAdvance` says `:next`: a page FillFields did not consume); after the claim every halt is `submit_unverified` |
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
  `navigation_recipe`, `answer_override(field)`, `readiness` (`Base::Readiness.visible_fields(min:, root:)` or
  `.schema_keys(keys:, attr:, ratio: 0.8, root:, key_prefix: nil)`; `key_prefix` is the platform's per-render prefix of
  the `attr` values as ONE regex source valid in Ruby and JS, shared with its `field_key`), `apply_key`.
- Hooks with defaults: `excluded_regions` (`[]`), `form_root_selector` (nil), `field_key(raw)` (`raw.default_key`;
  `raw` is `Base::RawField(element, default_key)` with `#attr(name)` over the snapshot element's `attrs`),
  `answer_hints` (`{}`), `semantic_for(field)` (nil; the semantic a platform field key names, Ashby `_systemfield_*`;
  `Answer::Classify` asks first), `fill_order(fields)` (identity), `success_evidence`
  (`{ texts:, url_patterns:, selectors:, failure_selectors:, submit_request: { url:, body_ok: } | nil, min_signals: }`;
  `selectors` / `failure_selectors` are optional CSS lists, default `[]`), `gates`.
- No transport / action methods (`reach_form`, `fill`, `submit` ...) on the adapter.

`Apply::Platform::Generic` (key `generic`, no signals, `readiness` → `:ai_only`, `Platform::Base#ai_only?`) is what
`Detect` returns below the threshold. Its form is reached by the [Navigator](#navigator-generic) and accepted only by R2;
no readiness poll ever claims a generic page is the form. `success_evidence` → `{ texts: SUCCESS_TEXTS, url_patterns:
SUCCESS_URLS, submit_request: nil, min_signals: 2 }`: thank-you / received / submitted texts in uk, en and ru, and
`thank|success|confirm|received|applied` in the URL's path / query / fragment (never the host). One deterministic signal
plus the AI's corroboration counts as submitted; the AI alone never does (design R13). Every external DOU apply whose
platform no adapter knows runs as Generic.

`Apply::Platform::Registry`: `PLATFORMS = %w[Apply::Platform::Ashby]`, `BOARD_PLATFORMS = []` (phase 4, pinned, never
detected), `THRESHOLD = 0.8`, `FINGERPRINT_VERSION = 1`; memoized `platforms`, `dom_markers` (selectors of all
`:dom` signals), `known_hosts` / `known_host?(host)` (`:host` signal patterns), `fingerprint` (SHA256 of version +
key/priority/signals; part of `DetectPlatform.input_digest`), `find!(key)` (Generic for `generic`, `ArgumentError`
otherwise).

### Ashby

`Apply::Platform::Ashby` (design §5.3). Every URL and pattern comes from `self.origin`
(`https://jobs.ashbyhq.com`): `job_url`, `submit_url`, `canonical_form_url`, the schema endpoint. A spec subclass
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
| success_evidence | `texts: SUCCESS_TEXTS` (application submitted / received, thank you for applying / your application), `selectors: SUCCESS_SELECTORS` (`.ashby-application-form-success-container`), `failure_selectors: FAILURE_SELECTORS` (`.ashby-application-form-failure-container`, `.ashby-application-form-blocked-application-container`), `submit_request` on `submit_url` (`<origin>/api/non-user-graphql?op=` one of `SUBMIT_OPS` = `ApiSubmitSingleApplicationFormAction`, `ApiSubmitMultipleFormsAction`; never ApiSetFormValue / upload ops) with `body_ok: Ashby.submit_accepted?` (no `errors`; the `data` value holding `applicationFormResult` — alias `submitApplicationFormAction` / `submitMultipleFormsAction` — has `__typename == 'FormSubmitSuccess'` for it and every `surveyFormResults` entry; `messages.blockMessageForCandidateHtml` blank), `min_signals: 2` |
| apply_key | `ashby:<slug>:<jid>` |

What Ashby's SPA does on submit (live bundle, read-only; confirmed by apply 227's post-submit DOM): a reCAPTCHA token
(~1 s), then a JSON POST of `ApiSubmitSingleApplicationFormAction` (Apollo HttpLink, `?op=<operationName>`; field
values were stored earlier by `ApiSetFormValue`). The answer is HTTP 200 either way: `FormSubmitSuccess`, or
`FormRender` for a validation re-render. On success the confirmation view replaces the form INSIDE
`#form[role=tabpanel]`: `.ashby-application-form-success-container[role=status]` with a "Success" heading and the org's
`applicationSubmittedSuccessMessage` (Preply: "Application received! Thank you for taking the first step...") or the
default "Your application was successfully submitted...". The URL does not change. The copy is per org, so the
container (`success_dom`) and the mutation (`submit_request`) are the copy-independent pair; the texts are a third
signal. Datadog RUM beacons fire around the submit (ignored by NetTracker). Ashby markers in `Platform::Ashby`:
`SUCCESS_SELECTORS` (`.ashby-application-form-success-container`), `FAILURE_SELECTORS` (failure and blocked-application
containers; a blocked candidate still gets `FormSubmitSuccess`), `SUCCESS_TEXTS`, `SUBMIT_OPS` / `submit_url` (the
submit mutation only, never `ApiSetFormValue`) and `submit_accepted?` (no GraphQL errors, every form result
`FormSubmitSuccess`, no block message), `min_signals: 2`. The real post-submit DOM (scripts stripped) is the regression
fixture `spec/fixtures/files/apply_engine/ashby/post_submit_success.html` (`verify_submit_ashby_dom_spec.rb`).

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
| `CloudflareInterstitial` | after_goto | main frame title / outline matches `Client::Response.cloudflare_interstitial?` (the one marker predicate; Goto already waited `WaitPastCloudflare` 40 s) | `Halt(:bot_wall, detail: 'cloudflare')` |
| `ExternalMessenger` | http_resolved, after_goto | main URL on `t.me`, `telegram.me`, `wa.me`, `m.me` (embedded frames ignored) | `Halt(:external_messenger)` |
| `SignInWall` | http_resolved, after_goto, after_action | main URL on `OAUTH_HOSTS` (accounts.google.com, login.microsoftonline.com, linkedin.com/oauth, linkedin.com/uas/login, github.com/login), or a visible password field in the snapshot | `Halt(:login_required)` |
| `DataDome` | http_resolved, after_goto | `captcha-delivery.com` in hops / current URLs / scripts / frames, or snapshot captcha `datadome` | `Halt(:bot_wall)` |
| `ClosedPosting` | after_goto, after_action | a frame's outline headings (never its `tabs ...` entries) / alerts match `CLOSED_LEXICON` (en / uk / ru; the adjective-first "Закрита вакансія" / "Закрытая вакансия" only as a whole singular line, so a "Закриті вакансії" filter or list heading is not a closed posting) AND that frame has no visible fillable control (`BuildFieldInventory.control?`, filled or empty, except a LONE filled select / combobox, the language switcher of a closed page): a form page with a "closed" footer line stays silent, also after its last fill | `Halt(:closed_posting, detail: matched text)` |
| `CookieConsent` | after_goto, after_action | a visible enabled button whose whole name matches `CONSENT_LEXICON` (necessary / essential only, reject all; uk + en), else `LAST_RESORT` (accept all) | clicks it (`session.click` + `settle(:click)`), never raises; at most `MAX_CLICKS = 2` per session |
| `VisibleCaptcha` | after_action, before_submit | snapshot captcha `recaptcha`, `recaptcha_challenge`, `hcaptcha`, `turnstile` (invisible kinds ignored) | `Halt(:manual_apply_required, detail: :captcha)` (§18) |
| `EmailCode` | after_submit | a frame's outline / alerts match `CODE_LEXICON` AND it has a visible text input with `autocomplete=one-time-code` or a name / id / placeholder like code / otp / verification | `Engine::AwaitInput` (parks the run), returns true; otherwise nil |

GoogleForms runs before SignInWall so a Google Form redirecting to accounts.google.com is "apply yourself", not
"login required". CloudflareInterstitial runs before ExternalMessenger / SignInWall so a wall is reported as `bot_wall`, ClosedPosting
before CookieConsent (a closed page's banner is irrelevant), EmailCode last (it parks the run).

### Awaiting input (EmailCode)

After the submit click (the claim already exists) `Gate::EmailCode` finds a code page and calls
`Engine::AwaitInput.call(ctx:, kind: 'email_code', field_element:, frame:)`:

1. `expires_at = now + min(MAX_WAIT, ctx.remaining - RESERVE)`; `MAX_WAIT = 5 min`, `RESERVE = 60 s`; nothing left is
   `Halt(:email_code, 'no time to wait')`.
2. Fenced `persist!(stage: AwaitInput::STAGE ('awaiting_input'), input_request: { kind, requested_at, expires_at }, input_response: nil)` +
   `Engine::Broadcast`: the UI shows the code box (`Apply::Component::InputRequest`, "UI").
3. Every `POLL_INTERVAL = 3 s`: `ctx.check_fence!`, then `Apply.where(id:, run_token:).pick(:input_response)` (primary
   key). The apply thread is parked here (one thread per browser slot); the heartbeat TimerTask keeps the row alive.
4. The user posts the code to `Apply::Operation::ProvideInput`, which stores `input_response` `{code, at}` with ONE
   guarded UPDATE (`state = running AND stage = AwaitInput::STAGE AND input_request IS NOT NULL`; 0 rows is
   `not_allowed`). `AwaitInput::STAGE` is the ONE name of the stage (ProvideInput and `Component::InputRequest` read
   it). The `code` param is filtered from the request log (`/\Acode\z/` in `config/initializers/filter_parameter_logging.rb`).
5. Code received: request and response are cleared, stage back to `submit`; the code is written through `SetFieldValue`
   (read-back; a `Mismatch` is `Halt(:email_code, 'code not accepted')`), the ONE visible `submit_like` button of the
   frame is clicked (Enter in the input when there is not exactly one), `settle(:submit)`, trace `email_code_entered`
   (never the code). Verify runs as usual.
6. Timeout (the poll loop ends at `expires_at`): ONE fenced, guarded UPDATE closes the request
   (`FencedUpdate(attributes: { input_request: nil, stage: 'submit' }, extra_condition: { input_response: nil })`).
   0 rows means a code arrived after the last poll (the user answered in time): it is read and used as in 5. Once the
   request is closed, ProvideInput's guard refuses a late code. Nothing stored → `Halt(:email_code)`; the claim rule
   lands it in `submit_unverified`.

Columns `applies.input_request` / `input_response` (jsonb); cleared by `AwaitInput`, by `StartContext` (a resumed run
never consumes a stale code) and by `Lifecycle::Decide#attributes` (`input_request: nil` on every halt, so no apply
shows "awaiting input" forever). The stage name has the locale key `apply.stage.awaiting_input`.

## Stages: DetectPlatform, FetchSchema

`Apply::Operation::Stage::Base < Apply::Operation::Base` adds `self.input_digest(ctx, **)` (nil = always run; else a
succeeded step row with the same digest lets the Runner skip and call `self.restore(ctx, result)`) and
`step_result(**data)` (stored by the Runner in `apply_steps.result`, see Runner).

| Stage | key | Flow | input_digest | restore |
| ----- | --- | ---- | ------------ | ------- |
| `DetectPlatform` | `detect` | `CollectHttpEvidence` → `RunGates(:http_resolved)` → `ctx.redetect!` → `CheckApplyKey` → `persist!(platform:, platform_match:, apply_key:, entry_url:, landing_url:)` (`landing_url` = the walk's final URL, unredacted; `Context#landing_url` reads it, else the entry URL) ; step_result `{ match, evidence }`. No entry URL → `no_application_path` | SHA256 of entry URL + `Registry.fingerprint` | re-adopts the match (from the unredacted `applies.platform_match` when it names the same platform, else the result); rebuilds the evidence with `current_urls: [applies.landing_url]`, the stored `hops` / `dom_markers`, and NO `script_srcs` / `iframe_srcs` / `host_aliases` (never URL evidence from the redacted result) |
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
   Ashby `_systemfield_*`) -> `password` flag -> `file` kind (by label first, `Classify#file`: resume-parse helper ->
   `other`; cover / motivation letter -> `cover_letter`; label names the CV (`cv_file`) -> `cv`; portfolio / additional
   / other attachments (`extra_files`) -> `other`; no label (blank or a generic "Attach") -> `cv`; any other label ->
   `cv` when required, else `other`) -> `email` / `tel` kind -> `field.autocomplete` (`Classify::AUTOCOMPLETE`) ->
   label (then placeholder) against `config/apply/field_semantics.yml` (uk / en / ru regexes, first semantic wins,
   sensitive ones first, a regex under one semantic only) -> `other`. The text is normalized first
   (`Classify::TRAILER`: trailing `* : . ? !` and a trailing `(...)` note cut). Profile-fact patterns (names, email,
   phone, country, location) are anchored to the whole label and `consent_required` names consent wording only, because both
   are answered at confidence 1.0 with no review reason: "Are you open to relocation?", "Name of your current
   employer" or "Do you agree to work from the office?" must reach the AI as `other`. A bare "Country" is `country`, not
   `location`: a city typed into a country picker matches no option. Nationality / national origin
   are `demographic`, citizenship is `legal_status`.
4. **Sensitive semantics never reach the AI.**
   `password` -> `Halt(:login_required)`; `demographic` -> the user's explicit `demographic` fact (matched to the
   options), else the "decline to self-identify" option (`decline` lexicon, source `policy`), else empty when optional /
   `Halt(:missing_profile_fact, detail: field id)` when required; `legal_status` -> the `work_authorization` fact only,
   else the same empty / halt.
5. Profile facts (`Answer::ResolveFact`: `UserProfile#fact`, `email` falls back to `user.email`, `full_name` to the profile
   name, `country` to the last comma-separated part of the `location` fact ("Kyiv, Ukraine" -> "Ukraine"), languages are joined; `cv` -> `Answer::FileRef.cv`, stored as `{ 'file' => 'cv' }`). A fact that does not fit
   the field's options goes to the AI instead. A file field with any other semantic (a platform key mapping it to
   `cover_letter`, ...) never reaches the AI: empty when optional, `Halt(:missing_profile_fact)` when required (an AI
   string would become an upload path; `Stage::FillFields` also uploads only a `FileRef`, never a string answer).
6. Consent (`Answer::ResolveConsent`): `consent_required` -> checkbox `true`, or the option `Engine::MatchOption` finds for
   the `affirm` lexicon (`Classify.option_label_for`, the one phrase-to-option rule, also used for the `decline` option;
   a list when `field.multi_valued?`); source `policy` when `users.auto_consent` (default **true**, design
   §18.3), `policy_pending` when the user opted out. No affirmative option: a required field gets
   `{ value: nil, source: policy_pending }` and the user fills it in the review form; an optional one stays empty.
   `marketing_opt_in` is never set (`Answer::Resolve` returns nil for it; `ResolveConsent` only sees `consent_required`);
   a `marketing_opt_out` checkbox ("I do not want to receive the newsletter") is CHECKED (source `policy`): unchecked it
   would opt the user in. Its lexicon needs a negated subscription phrase, or a whole-label "Unsubscribe" / "Opt out
   (of marketing emails)": an opt-in or consent text ending "you can unsubscribe at any time", or an EEO "you may opt
   out of answering", must never classify as an opt-out (it would be ticked).
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
| `unknown_platform` | `review_policy` is `unknown_platforms` and the platform is unknown (a Generic form the Navigator reached) | policy |
| `low_confidence` | an `ai` answer with confidence < 0.5 | safety |
| `approximate` | an answer picked as the nearest option | safety |
| `consent_pending` | a `policy_pending` answer (user opted out of `auto_consent`) | safety |
| `foreign_origin` | (`Engine::CheckOrigin`) the registered domain (`PublicSuffix`) of `form_url` is not a known platform host and not one of the entry URL / detection hops / landing URLs | safety |
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
`required`, `filled`, `visible`, `prefix` (fixed letterless text just before a text input, e.g. `+380`; never part of `name`),
`disabled`, `password`, `search_like`, `submit_like`, `scope` (`dialog` / `form` [`#id`] or null), `regions` (which of the requested `regions` selectors contain it),
`root_strategies` (the field root) and `target` (an `ApplyMate::Client::Browser::Target` with its `frame_path`).

`Engine::FormElements.snapshot(ctx)` asks for the regions `[form_root css, *platform.excluded_regions]`;
`FormElements.call(ctx:, snapshot:)` keeps the elements whose `target.frame_path == form_root.frame_path`, whose
`regions` include the form root selector and none of the excluded regions (`Halt(:not_a_form)` without a form root).
Inventory, FillFields' submit-button check and Submit all read the page through it.

## Reach form

`Stage::ReachForm` (key `navigate`; `navigate:replay:submit` with `replay: true`) →
`Engine::ReachForm.call(ctx:, navigation:)`, model = the navigation (array of op hashes). `navigation:` is
`applies.navigation` in replay mode, nil in the survey:

R. **replay** — a stored navigation (submit scope): its ops through `Recipe::Interpret`, then readiness unless its
   `WaitFor` already set `ctx.form_root`. `Drift` (or no readiness) → trace `recipe_drift`, the drifted op becomes the
   Navigator's heal hint and the paths below take over from the page the replay left. The survey's `form_root` is
   cleared by `Interpret`, so the submit scope always finds its own.
0. **land** — generic match on a fresh (`about:blank`) lease → `Goto('{landing_url}')` and a poll of
   `Engine::Observe(:after_goto)` until the platform is known: `LANDING_TIMEOUT = 20` s when the HTTP level found a
   `probable` platform (Preply's `?ashby_jid=`), else `IDENTIFY_TIMEOUT = 5` s, ended at the first poll when nothing is
   probable and the page already renders a form (`ReachForm#form_rendered?`: `session.ready?(body, timeout: 0,
   min_fields: WaitReady::DEFAULT_MIN_FIELDS)`); traced `landed` (`identified`, `form_rendered`).
1. **unwrap_canonical** — `platform.canonical_form_url` present, not yet unwrapped for this platform in this session
   (`ctx.scratch.canonical_unwrapped`, appended by `Op::Unwrap#perform!` whoever runs it), and not the current page by
   `CheckApplyKey.normalized_url` (host + path) → `[Unwrap('{canonical_form_url}')]` through `Interpret`.
2. **run_recipe** — `platform.navigation_recipe` (array of op hashes) through `Interpret`.
3. **current page** — nothing navigated and the lease is not on `about:blank` → readiness check on the page as is
   (navigation `[]`; e.g. the embed iframe of a company page).
4. **navigate!** — the [Navigator](#navigator-generic) (`Engine::Navigate.call(ctx:, heal_hint:)`) from the page the
   earlier paths left; never on a blank lease (→ `Halt(:not_a_form)`). When it hands over to a platform it identified
   (no form root yet), that adapter's paths 1–3 run once; nothing ready then → `Halt(:not_a_form)`.

Each path 1–3 then waits `WaitReady(timeout: ctx.clamp(READY_TIMEOUT = 30))` unless a `WaitFor` op set
`ctx.form_root`, never for an `ai_only` platform (Generic); ready → `ctx.form_root`, `ctx.form_url =
session.current_url`. `Drift` in path 1 or 2 counts as not ready (traced). A path that navigated is never followed by
a wait on the current page. Every path either sets a form root or halts: there is no "succeeded without a form"
result. model = the landing goto (when there was one) + the ops of the path that reached the form; before the
Navigator's ops, the ops of the last path that moved the page without reaching it (`@trail`, stored `wait_for`
excluded), so a replay starts where the Navigator started. The stage persists `navigation:` = what was actually
performed and `form_url`; the replay step has no input digest (always re-runs).

**Recipe = a plain Array of op hashes** (`applies.navigation`, `Platform#navigation_recipe`; phase 6 stores learned
ones). Op plugins in `app/concepts/apply/recipe/op/` are thin: they drive the Session through the engine's guards
and settle; `Interpret` owns order, tabs, gates, redetection and drift.

| op | hash | perform! | settle | gate event | opens tab? |
|---|---|---|---|---|---|
| `goto` | `url_template` | `session.goto(url(ctx))` | (goto's own waits) | `after_goto` | no |
| `unwrap` | `url_template` | goto of `{canonical_form_url}`, marks `canonical_unwrapped` | (goto's own waits) | `after_goto` | no |
| `click` | `target` (`Target#to_h`) | `GuardAction { session.click(target) }` | `:click` | `after_action` | yes |
| `press` | `target`, `key` ∈ `Press::KEYS = ArrowDown Enter Escape Tab` | `GuardAction { session.press(target, key) }` | `:key` | `after_action` | yes |
| `scroll` | `target` | `session.scroll_into_view(target)` | `:key` | `after_action` | no |
| `switch_tab` | `index` (Integer ≥ 0) | waits up to `SwitchTab::OPEN_TIMEOUT = 5` s (clamped) for tab `index`; sign-in host (`Gate::SignInWall.oauth_location`) → `Halt(:login_required)`; never opened → `Drift`; `session.switch_to(index)` | `settle_content` | `after_goto` | no |
| `wait_for` | `root` (CSS), `frame_path` (default `[]`), `min_fields` (Integer ≥ 1) | `session.ready?(Target.css(root, frame_path:), timeout: ctx.clamp(WaitFor::READY_TIMEOUT = ReachForm::READY_TIMEOUT), min_fields:)`; ready → `ctx.form_root`, `ctx.form_url`; not ready → `Drift` | — | `after_action` | no |

- `Op::Base.parse!(hash)` (string or symbol keys) → `OPS[op].from_h(attrs)`; `to_h` round-trips (`{ 'op' => …, attrs }`).
  Unknown op, unknown attribute (`Op.attributes`), bad key / index / target / `wait_for` values → `ArgumentError`;
  missing attribute → `KeyError`. `Op::Targeted` is the abstract base of click / press / scroll (`target` rebuilt
  with `Target.from_h`).
- **URL templates only**: a `goto` / `unwrap` `url_template` must start with a placeholder (`{entry_url}`,
  `{landing_url}`, `{canonical_form_url}`, `{current}`) and contain no `://` (`Op::Goto#initialize`, so every
  constructor path); an unknown placeholder or one without a value at perform time → `ArgumentError`.
- Behaviour switches are predicates on the op: `settle_kind`, `gate_event`, `opens_tab?` (click, press),
  `reaches_form?` (wait_for).

**`Recipe::Interpret.call(ctx:, ops:)`**: parses every op first (an invalid recipe touches nothing), clears
`ctx.form_root`, then per op: `ctx.check_fence!` → for an `opens_tab?` op, `session.pages.size` and
`session.probe(:opens_tab, target)` (before the action) → `op.perform!` → `Engine::Observe(op.gate_event)` → trace
`recipe_op` (`op`, `platform`, `url`). **New tabs** (design §6.3): after an `opens_tab?` op whose next op is not a
`switch_tab` (a recorded navigation keeps its own, so replays never grow), a page beyond the count → trace `new_tab`,
`SwitchTab(newest index)` is performed + observed and inserted into the model. The tab is looked for once, immediately, or
polled up to `SwitchTab::OPEN_TIMEOUT` when the probe said the target opens one (a tab is reported 0.5–1.5 s after
the click, after `settle(:click)`). Goto / unwrap never follow a tab (a popup on load does not take the session).
`TargetNotFound` from an op or its probe → `Drift(op)` (a stale locator is drift, not `target_not_found`).
`verify_form!` after the loop: a recipe whose last op `reaches_form?` must have set `ctx.form_root` AND the elements in
it must pass R2 (`FormElements.snapshot` → `FormElements` → `AssessFormLikeness`, traced `form_likeness`); otherwise the
root is cleared and `Drift(last op)` is raised (any platform: an adapter's recipe ending in `wait_for` gets the same
check). Others leave readiness to the caller. `Drift#performed` carries the ops performed before it. model = performed op hashes. Termination: one
pass over a finite list, ≤ 1 inserted `switch_tab` per op, every wait clamped to the scope deadline.

**Design mapping:** design `Recipe::Interpreter` → operation `Apply::Operation::Recipe::Interpret`;
`Recipe::Definition` → the plain op-hash Array; `Recipe::Drift` → `Apply::Operation::Recipe::Drift`. Replay lives in
`Engine::ReachForm` (path R) rather than in the stage, so readiness (`WaitReady` + `form_root` / `form_url`) has one
implementation. The design's per-op `expect` / `vacancy_title` check is not there: `verify_form!` (R2 after the terminal
`wait_for`) is the one form check. Not in the design: the `opens_tab` probe and the bounded tab wait (a browser reports a
tab after `settle(:click)` returns), and the sign-in check inside `SwitchTab` (one place for stored and inserted
switches; the Navigator's validator reuses `Gate::SignInWall.oauth_location`).

**`WaitReady.call(ctx:, timeout:)`**: readiness = `platform.readiness` or
`Readiness.visible_fields(min: 3, root: form_root_selector || 'body')`. Inside ONE `session.wait_until(timeout:)` it
polls `session.ready?(root, timeout: 0, keys:/attr:/ratio:/key_prefix:` or `min_fields:)` in the top frame and every `http(s)` frame
(first `MAX_FRAMES`, child frames addressed by `url_contains`); model = the root `Target`, its `frame_path` taken from
the snapshot (`iframe#id` hop for the Ashby embed), or nil when the window ends.

| Stage | key | Flow | input_digest | restore |
| ----- | --- | ---- | ------------ | ------- |
| `ReachForm` | `navigate` | `Engine::ReachForm(navigation: replay ? applies.navigation : nil)`; `persist!(navigation:, form_url:)` (the performed ops); step_result `{ navigation, form_url, form_root }` | SHA256 of match key + captures and schema ids; nil with `replay: true` (always re-runs: replays the stored navigation) | `form_url` from `applies.form_url`, `form_root` from the result |
| `DiscoverFields` | `discover` | `FormElements.snapshot` → `RunGates(:after_goto)` → for an `ai_only` platform (Generic) R2 (`AssessFormLikeness` over `FormElements`; rejected → `Halt(:not_a_form, detail: 'not an application form (<reason>)')`) → `BuildFieldInventory` → (`reconcile: true`) `ReconcileFields` with `apply.field_list`; `persist!(fields:)`; trace `fields_discovered`; step_result `{ fields: n }` | SHA256 of match key + captures, schema ids, `Registry.fingerprint`; nil with `reconcile: true` | `ctx.fields = apply.field_list` |
| `FillFields` | `fill` | see Widgets | nil | - |
| `Submit` | `submit` | see Submit and Verify | nil | - |
| `Verify` | `verify` | see Submit and Verify | nil | - |

## Navigator (Generic)

`Apply::Operation::Engine::Navigate.call(ctx:, heal_hint: nil).model` (design §6.3 `Engine::Navigator`; the design's
`Guard` and `Budget` are private state inside it, not classes) is the bounded observe → decide → act loop that takes the
session from the current page to the application form when no adapter path reached it (`Engine::ReachForm` path 4).
model = the op hashes performed (recipe ops), ending with `wait_for` when the AI reached the form. On any raise nothing
is persisted: `Stage::ReachForm` stores only a navigation that reached the form.

One turn:

1. **tick** — `turn > MAX_TURNS` → `Halt(:budget_exhausted)`; monotonic clock past `now + min(MAX_SECONDS +
   ctx.ai_allowance(Context::SCOPE_AI_CALLS), ctx.remaining)` (taken at start; the allowance is 0 for an API client,
   `4 * 180 s` for GeminiScraping; `ctx.remaining` already includes the scope deadline) → `Halt(:deadline)`.
2. **observe** — the previous action's fresh snapshot (no double snapshot), else `session.snapshot_all(markers:
   Registry.dom_markers)` → `Engine::Observe` (`RunGates(:after_goto)` after a navigation / tab switch,
   `:after_action` otherwise: CookieConsent resolves, SignInWall / VisibleCaptcha / GoogleForms / ... halt) →
   `ctx.redetect!`. A gate that resolved something (a banner clicked away) makes the snapshot stale: one new look.
3. **hand over** — the match became a known platform other than the one the Navigator started with → trace
   `navigator_handover`, return (ReachForm runs that adapter's paths once). A platform with deterministic readiness
   (not `ai_only?`) whose form is ready within `READY_TIMEOUT = 2` s → `ctx.form_root` / `form_url`, return.
4. **guard** — `@seen[[current_url, snapshot.digest]] += 1`; the `STUCK_AFTER = 3`rd visit of one state →
   `Halt(:stuck, detail: url)`. An observation after an **idle** turn (only `wait`s and rejected actions performed, no
   FORBIDDEN skip) goes to `@idle_seen` instead: it trips stuck only when `@seen + @idle_seen` reaches
   `STUCK_AFTER + MAX_IDLE_REPEATS` (3 + 3), so an embedded app still booting in its iframe gets waits, not strikes.
   A `wait` (`WAIT_SIGNATURE = 'page wait'`) never becomes FORBIDDEN.
   **evident** — before any AI call, once per `snapshot.digest` (`@evident_tried`), and only when the adopted platform
   has no deterministic readiness (`Navigate#platform_readiness?` false: no platform or an `ai_only?` one; a platform's
   own WaitReady in step 3 is its only deterministic claim, so a `<form>` lacking its schema keys is left to the AI):
   for each visible `submit_like`
   element inside a `<form>` (`Navigate#form_path`, the deepest `FORM_SEGMENT` of its css path), the elements under that
   form in its frame → `AssessFormLikeness(...).evident`; the first that passes is claimed without the AI (trace
   `navigator_evident_form`; `scope_ref` = `submit_ref` = the submit, `field_refs` = its visible controls) through the
   same form_reached path (7). Accepted → return, no AI call spent (a form rendered on load survives an AI outage);
   rejected → the claim's error is dropped and step 5 runs this turn. A submit outside any `<form>` is never claimed here.
5. **decide** — `Engine::CallAi(prompt: Prompt::Navigate, schema: ResponseSchema::Navigate, requires: %i[json_schema],
   system: prompt.system)` → `Navigate::Decision = Data.define(:status, :reason, :actions, :form, :give_up_code)`.
   `InvalidResponse` / `EmptyResponse` (incl. a schema-valid but unusable answer, see the schema) → asked again with
   the error in `errors:` (a counted call); `MAX_INVALID_IN_A_ROW = 2` in a row → `Halt(:invalid_ai_output)`.
   Traced `navigator_turn` / `navigator_invalid`. The prompt lists visible elements except `file_trigger`s and
   nameless buttons inside a field (`Prompt::Navigate#field_part?`: name blank, `question` set, no `group` - a
   combobox's arrow toggle). A rejected action goes into the next prompt's errors with `REJECTION_HINTS` text when
   its code has one (`frame_ref`: actions take element refs `fN:eM`; there is no page scroll).
6. **give_up** → `Halt(give_up_code)` (trace `navigator_give_up`), except `captcha_challenge` →
   `Halt(:manual_apply_required, detail: :captcha)` (§18, `GIVE_UP_HALTS`). A missing code is invalid output.
7. **form_reached** → the claimed root: a `dialog` scope (`CONTAINER_ROLES`) is the root itself (its `css` path);
   otherwise the closest common ancestor of the `css` paths (`tag:nth-of-type` chains from snapshot.js) of `scope_ref`,
   `field_refs`, `submit_ref` and `advance_ref` in the scope's frame, widened to the enclosing `<form>` when there is
   one. Either path is then re-addressed by `probe(:anchor)` (`Navigate#anchored`, probe/anchor.js): a stable `#id`,
   `tag[data-*]` / `tag[name]`, `tag[role][aria-label]`, the page's only `form`, or the nearest such ancestor plus a
   few `nth-of-type` steps (`#form > div:nth-of-type(2)`); the absolute path only when nothing on the way up is stable.
   A banner inserted above the form then does not shift a replayed `wait_for`. No root → rejected (`no_root`). Then a fresh
   `snapshot_all(markers:, regions: [root_css])`, the elements of the root's frame → `AssessFormLikeness(root:)` (R2)
   and `CheckOrigin` (judged on the current URL, kept only when accepted); traced `form_claim` (`accepted`, `reason`,
   `fillable`, `file_inputs`, `root`, `origin_ok`, `host`). Accepted → `ctx.form_root = Target.css(root_css,
   frame_path:)`, `ctx.form_url`, `ctx.scratch.claim_left_out` (`Navigate#left_out`: the css paths,
   `BuildFieldInventory.dom_key`, of the optional fillable controls in the root the AI saw and left out of
   `field_refs` - a helper upload; never a required control, and none at all when `field_refs` is empty or more were
   left out than listed; reset by `close_scope!`, read once by `Stage::DiscoverFields` in the survey), append
   `WaitFor(root:, frame_path:, min_fields: <probe(:readiness) fields under the root>.clamp(1, WAIT_FOR_MAX_FIELDS = 3))`
   (the replay's `Session#ready?` counts with the same probe, so the stored minimum never drifts), return. Rejected → the reason goes into the next prompt's errors; the next turn (already
   counted) looks again.
8. **continue** → at most `MAX_ACTIONS_PER_TURN = 3` actions, each through `Engine::ExecuteAction` against the snapshot
   the AI saw (a click / press that changed nothing gets ONE second look, `ExecuteAction::SECOND_LOOK_SECONDS = 2.5`,
   before it counts as "no change": a modal that fades in after the network settle; the URL / tab count is read
   again after the look, so a delayed JS redirect is `navigated`, and a look whose snapshots all failed keeps the
   post-action snapshot): an action whose signature
   (`"<fingerprint> <type>"`, `"tab:<i> switch_tab"`, `"page wait"`) is in
   `@forbidden` is skipped; a rejected one → its reason into the next prompt's errors; a performed one → its ops into
   the recipe, trace `navigate`. The batch stops at the first page change (`page_changed`); when nothing changed,
   every performed action becomes FORBIDDEN (listed by its current ref in the next prompt).

**What makes it stop when the world stays broken:** every turn counts (12), the 180 s monotonic budget, the stuck
guard (same state 3×: a repeated no-op action is skipped as FORBIDDEN, so the state repeats), two invalid answers in a
row, `CallAi`'s caps, the scope deadline (`Context#scope_deadline`: 8 min, 20 min with GeminiScraping), the lease TTL
(the scope deadline + 60 s, at most browserd's `LEASE_TTL_S = 1800`) and the run's `deadline_at` (30 / 54 min).

| Budget | Value | Where |
|---|---|---|
| turns | `Navigate::MAX_TURNS = 12` | `Halt(:budget_exhausted)` on turn 13 (12 AI turns at most) |
| time | `Navigate::MAX_SECONDS = 180` s + `ctx.ai_allowance(Context::SCOPE_AI_CALLS = 4)`, clamped to `ctx.remaining` | `Halt(:deadline)` |
| actions per answer | `MAX_ACTIONS_PER_TURN = ResponseSchema::Navigate::MAX_ACTIONS = 3` | schema `maxItems` + `first(3)` |
| same state | `STUCK_AFTER = 3` (`+ MAX_IDLE_REPEATS = 3` after idle wait / rejected turns) | `Halt(:stuck)` |
| invalid answers in a row | `MAX_INVALID_IN_A_ROW = 2` | `Halt(:invalid_ai_output)` |
| AI calls | `CallAi::MAX_AI_CALLS_PER_ATTEMPT = 30`, `MAX_AI_CALLS_PER_APPLY = 90` | `Halt(:ai_budget_exhausted)` / `Halt(:ai_lifetime_cap)` (SQL-side counter) |
| one AI call | `Request::TIMEOUTS[:navigate] = 60` s clamped by `CallAi`; `CallAi::TRANSIENT_RETRIES = 2` deadline-clamped retries of `Unavailable` | `capacity` / `ai_quota_exhausted` |
| wait action | `ExecuteAction::MAX_WAIT_MS = 5_000` (default `DEFAULT_WAIT_MS = 2_000`) | clamped, then `ctx.clamp` |

**Action vocabulary** (closed; `ResponseSchema::Navigate::ACTION_TYPES`; there is no `fill`):

| type | arguments | performed as | recorded op |
|---|---|---|---|
| `click` | `ref` | `Op::Click#perform!` (GuardAction: gates, one obstruction retry; `settle(:click)`) + new-tab rule | `click` (+ `switch_tab`) |
| `press` | `ref`, `key` ∈ `Op::Press::KEYS` | `Op::Press#perform!` + new-tab rule | `press` (+ `switch_tab`) |
| `scroll` | `ref` | `Op::Scroll#perform!` (`scroll_into_view`) | `scroll` |
| `navigate` | `ref` with an `href` | `session.goto(absolute href)` (Session's PublicAddressGuard again) | `click` on the link: recipes hold URL templates only, never a literal URL |
| `switch_tab` | `index` | `Op::SwitchTab#perform!` | `switch_tab` |
| `wait` | `max_ms` | `session.wait_until(timeout:) { snapshot digest changed }` | nothing |

**`Engine::ExecuteAction.call(ctx:, action:, snapshot:, allowed: ALL_TYPES)`** (design `Engine::Executor`): model = the
performed op hashes (`[]` when rejected); `result[:rejected]` (reason or nil), `result[:navigated]` (URL or tab count
changed), `result[:page_changed]` (navigated or digest changed), `result[:snapshot]` (a fresh snapshot after the
action, the AI's own when rejected). A rejection never touches the session, never raises, and is traced
`action_rejected` (`type`, `ref`, `reason`):

| Rule | reason |
|---|---|
| type not in `allowed` / the vocabulary | `action_not_allowed` |
| `click` / `press` / `scroll` / `navigate` ref not in the snapshot (hallucinated) | `unknown_ref` |
| `click` / `press` / `scroll` / `navigate` on a frame's ref (`f0`: a page-level scroll) | `frame_ref` |
| `click` / `press` on a `submit_like` / `password` element | `submit_like` / `password` |
| `click` / `press` on what sends the application by NAME (`sends_application?`, never on an `<a>` whose href navigates: not `#`, not `javascript:`): a `ClassifyAdvance::FINAL_LEXICON` verb (send / submit / apply / respond) on an element with a `scope` (dialog / form, unique per container) that holds another visible fillable control, or a `SnapshotAll::SUBMIT_TEXT` verb outside any scope on a frame with another visible formless fillable control (an SPA form without a `<form>`). A launcher on the page itself ("Apply now", a `data-toggle=modal` "Надіслати резюме") stays clickable | `submit_like` |
| `click` / `press` on a file input's chooser link / button (snapshot.js `file_trigger`; it only opens the OS file dialog) | `file_trigger` |
| `press` key not in `Op::Press::KEYS` | `unknown_key` |
| `press Enter` on a fillable control (`BuildFieldInventory.control?`): implicit form submit | `implicit_submit` |
| `navigate` without `href` | `no_href` |
| `navigate` href (resolved against its frame URL) fails `ResolvePublicAddress` (`UnsafeUrlError`: private / non-http(s)) | `private_address` (NOT a halt here) |
| `navigate` to a sign-in host (`Gate::SignInWall.oauth_location`) | `sign_in_host` |
| `switch_tab` index outside `session.pages` / a sign-in tab | `unknown_tab` / `sign_in_host` |
| the target vanished before the action (`TargetNotFound`) | `target_not_found` |

New tabs: `Engine::AdoptNewTab` (the one rule, shared with `Recipe::Interpret`): `AdoptNewTab.watch(ctx, target)`
before an `opens_tab?` op, `AdoptNewTab.call(ctx:, **watch)` after it; a tab beyond the count is switched to (sign-in
host → `Halt(:login_required)`) and its `switch_tab` op appended.

**R2 — `Engine::AssessFormLikeness.call(elements:, root: nil)`** (design §6.4 `Engine::FormLikeness`; ONE implementation
for the Navigator's claim, `Recipe::Interpret#verify_form!` after a terminal `wait_for`, and `Stage::DiscoverFields` for
an `ai_only` platform). model = `AssessFormLikeness::Verdict = Data.define(:accepted, :reason, :fillable,
:file_inputs, :evident)`; `evident` (the Navigator's pre-AI claim) = a file input AND ≥ `MIN_FILLABLE` visible units
with an identity field AND a visible `submit_like` element (false on a visible password). `root:` keeps only elements whose `regions` include it. Any `password` element → rejected `password`.
Counted: controls by `BuildFieldInventory.control?` (the inventory's own predicate: no `search_like` — snapshot.js marks
`type=search`, `role=search`, `header`, `footer`, `nav:not([role=tablist])` — no `disabled`), visible, one unit per
`group_key`. A file input (visible or hidden) → accepted `file_input`; fewer than `MIN_FILLABLE = 3` units →
rejected `too_few_fields` (an email-only newsletter box); one unit classifying (`Answer::Classify` on a minimal
`Apply::Field`: label / placeholder / autocomplete / input kind) to `full_name` / `first_name` / `email` → accepted
`identity_field`; else rejected `no_identity_field`.

**Origin.** Every accepted claim is traced with `CheckOrigin` (the one `foreign_origin` rule); the review reason
`foreign_origin` is raised later by `Answer::ReviewReasons` from `ctx.form_url`, whatever `review_policy` is.

**Heal mode.** A stored navigation that drifts on replay (`Recipe::Drift`) → `Engine::ReachForm` passes the drifted op
as `heal_hint:`; the prompt shows `HEAL the stored step <op> no longer works here`. The navigation then persisted is
the replay's ops before the drift plus the Navigator's ops.

**What `applies.navigation` stores** for a Generic form: `[goto {landing_url}, <performed ops>, wait_for {root,
frame_path, min_fields}]`, e.g. `[goto, click, switch_tab, click, wait_for]`. The terminal `wait_for` is what the submit
scope's replay waits on and what `verify_form!` re-checks with R2.

**Generic as the fallback.** `Platform::Generic#readiness` is `:ai_only`: no readiness poll claims a generic page is the
form; only an R2-accepted claim or a stored `wait_for` sets the root. The review reason `unknown_platform` is added only
when `users.review_policy == unknown_platforms` (default `never`, §18).

**Deviations from the design (Navigator).** The phase-wide list is in
"[Deviations from the design (phase 3b)](#deviations-from-the-design-phase-3b)"; specific to the Navigator:

- `navigate` is recorded as a `click` on the link (the design's compiler stores URL templates only).
- The form root is derived from the claimed refs (closest common ancestor / dialog), not from `scope_ref` alone: the
  snapshot lists interactive elements only, so a `<form>` / `<div>` container never has a ref of its own.
- Hand-over returns only when the match changed to a known platform the Navigator did not start with (returning on
  any known match would end a Navigator called after a known adapter's own paths failed).
- The stuck guard trips on the third identical state BEFORE asking, so the repeated action appears under FORBIDDEN in
  the second (last) prompt, not a third one.
- `Stage::ReachForm` never persists a navigation without a form root (no "succeeded, no form" result).

## Field inventory

`BuildFieldInventory.call(ctx:, snapshot:, left_out: Set.new)` → `[Apply::Field]`, one per control or group of
`FormElements` (minus the `left_out` dom_keys: `Stage::DiscoverFields` passes `ctx.scratch.claim_left_out` in the
survey, nothing when reconciling):

- **Controls** (`BuildFieldInventory.control?`, the one rule): inputs except buttons, `textarea`, `select`, grouped
  elements, `chooser` upload buttons and `textbox/combobox/radio/checkbox/switch` roles that are not `<button>`;
  `search_like`, `disabled` and non-rendered (`visible: false`, except a file input) elements are skipped, and so are
  `helper?` ones: a `captcha_artifact` (g-recaptcha / h-captcha / cf-turnstile response), aria-hidden, or ANY readonly
  control (a readonly input that opens a list is a `combobox` group instead). Resume-parse helpers
  (`Answer::Classify.helper_control?`, `field_semantics.yml` `helper_controls`: "Autofill from resume", "Autocomplete
  from resume", "Parse resume"; `Classify` never gives such a file field `cv`, it is `other`) are dropped, and
  so is an optional snapshot field with no label, no description and no or only a generic placeholder ("Type here...").
  Label: a group's question, else the control's name, else the question, else the placeholder without its trailing
  `*` / `✱` (`placeholder_label`; never a generic one nor a date mask); a generic name (`Classify.generic_name?`:
  `generic_names` + `affirm`, e.g. "Attach", or a name with no letter: "+380", "$") yields to the question. A checkbox keeps its name (`Widget::NativeCheck`
  clicks its label by that text); a generic one ("Acknowledge/Confirm") gets the question as `description`, which
  `Answer::Classify` reads only for such a label. Description: schema, else `described_by` (aria-describedby), else
  that generic checkbox's question, else snapshot.js `help` (the field root's help block beside the label: Ashby's
  `ashby-application-form-question-description`). Implied required:
  `REQUIRED_LEXICON` (a required word, or a `*` / `✱` left in the label / placeholder: Hurma / Vuetify validate in JS
  only), or a `CORE_SEMANTICS` classification (`full_name first_name last_name email phone cv`), where `cv` counts only
  when the label names the CV (`Classify.cv_file?`, `cv_file`); never when `OPTIONAL_LEXICON` matches ("Phone
  (optional)", "необов'язково"). Units: `group_key` (radio / option groups), checkboxes sharing a
  field root (→ `checkbox_group`), else one element.
- **Kind**: schema kind when `platform.field_key(RawField)` matches a `ctx.schema` id, else DOM (`text email tel url number
  textarea select multiselect combobox autocomplete radio_group option_group checkbox checkbox_group file date range
  rich_text`). DOM rules beyond the tag / type: a `chooser` element (snapshot.js: a visible button / `[role=button]` whose
  name matches `UPLOAD_LEXICON` with no `input[type=file]` in its field root) → `file`; a `role=combobox` text input with
  `aria-autocomplete` `list`/`both`, not readonly and without `aria-haspopup` (a typeahead, no select chrome) →
  `autocomplete` (`AUTOCOMPLETE_LISTS`), and so is an ARIA-less typeahead (snapshot.js `typeahead`: a `type=text`
  input beside a suggestion container, Lever's location input); a custom select (snapshot.js `combobox` group: a readonly
  input over a list of `[role=option]` / `[data-value]` items, an `aria-haspopup=listbox` button / div trigger) →
  `combobox`; a text input whose placeholder is a date mask (`Widget::DateInput.masked?`,
  e.g. `dd.mm.yyyy`) → `date`; `type=date/month/week/datetime-local` → `date`; `type=range` → `range`; a contenteditable
  → `rich_text`. A single-choice schema kind (`select combobox autocomplete radio_group option_group`) yields to the DOM's
  single-choice kind: Ashby's Boolean / small ValueSelect becomes `radio_group` or `option_group` as the page draws it.
- **Merge**: schema wins for label, description, required, options, condition (`source: 'schema_api'`); DOM gives widget,
  target, placeholder, max_length, accept and `default_value` (read_value of a `filled` text-like control).
  Without a schema match everything comes from the DOM (`source: 'snapshot'`, id `f_<signature>_<ordinal>`).
- **Target**: the element's target; groups get the field root as `root` (`:required` visibility is judged on it), file
  inputs keep the hidden input as target with the dropzone as root.
- **Options**: a select's / group's own; a `combobox` still `'dynamic'` is opened to read them
  (`Engine::ReadComboboxOptions`: `dom_mark`, click (`Engine::ClickControl`, shared with `Widget::AriaCombobox`: a target
   with `root` (not self-visible) whose probe `click_box` finds no box >= 4 px is clicked through its nearest ancestor
   with one, `{ ...strategy, 'ancestor' => n }`, react-select's DummyInput; keys and read-back stay on the input),
   `ArrowDown`, `wait_for_listbox(timeout: ctx.clamp(WAIT = 2))`, then
  `CLOSERS` (Escape, Tab, one more click) until no option is open, each given `CLOSE_WAIT = 0.5` s; labels as values; the list is closed whenever options showed
  or `probe(:read_value)['expanded']` is still true (an async geocoder opens an EMPTY menu); nil on nothing / more than
  `MAX_OPTIONS = 100` labels (a long country / city list is never stored cut: CoerceValue / MatchOption treat an Array
  as complete, so it stays `'dynamic'` and AriaCombobox type-filters at fill time) / `TargetNotFound` / `Obstructed`) for the first `MAX_PROBED_COMBOBOXES = 6` comboboxes per inventory;
  an `autocomplete` (options depend on the typed text), a probe that opened nothing and those past the cap stay
  `'dynamic'`. The signature is computed before the probe, so ids never depend on it.
- **Identity**: `signature = Apply::Field.signature_for(label:, kind:, option_labels:)`, `ordinal` = position among equal
  signatures (DOM order). Two fields with one id → `Halt(:unexpected_error, detail: 'field id collision')`.
- **Widget**: `Apply::Widget::Registry.find(field)&.key` (nil = no driver; FillFields halts `no_widget_driver` only if it
  must fill it); a `chooser` element is always `dropzone` (set explicitly: its kind alone, `file`, would pick
  `FileInput`; `Registry.find` prefers the stored key, so a stored field keeps its driver); an `autocomplete` from a
  snapshot.js `typeahead` is `typeahead` (`Widget::Typeahead`, never picked by kind).

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
still wrong → `Apply::Widget::Mismatch(field:, wanted:, read_back:)`, carrying `before` = the snapshot `GuardAction` took
before the first write (`RecoverField` diffs against it). Every write is read back. `result[:approximate]` =
`driver.approximate_pick` (`Widget::Base` default nil): the option label the driver picked although it does not match
the answer.

`Registry::DRIVERS` (precedence order; `drivers` / `by_key` memoized; `for(field)` → `Halt(:no_widget_driver, detail: kind)`):

| Driver (`key`) | Kinds | Write | Fallback | Read-back / accepted when | settle |
| -------------- | ----- | ----- | -------- | ------------------------- | ------ |
| `Dropzone` (`dropzone`) | file with `widget == 'dropzone'` (a `chooser` button: no file input in the DOM) | `upload(target, path, via_chooser: true)` (`:required`; `expect_file_chooser { click }`) | - | the zone's text (read_value: a button's `displayed` is its field root's text) includes the basename | `:file` |
| `FileInput` (`file_input`) | file | `upload(target, path)` (`:attached`: hidden / clipped input) | - | displayed file name == basename | `:file` |
| `AriaCombobox` (`aria_combobox`) | combobox | for `PREFIXES = [10, 4]`: `dom_mark`, click, unless readonly `fill('')` + `type(prefix)`, `press('ArrowDown')`, `wait_for_listbox(since:, timeout: ctx.clamp(5))`, `MatchOption` → click the option; none → `Mismatch` | - | chip / displayed text == matched option label | `:click` |
| `Autocomplete` (`autocomplete`) | autocomplete (typeahead) | for `PREFIXES = [10, 4]` (distinct): click, `fill('')`, `dom_mark`, `type(prefix)` (no ArrowDown: suggestions come from typing), `wait_for_listbox(timeout: ctx.clamp(MAX_WAIT = 5))`; a `MatchOption` match → click it; on the last prefix with suggestions but no match → click the FIRST one and expose it as `approximate_pick`; no suggestions at all → `Mismatch` | - | chip / input value == the picked label | `:click` |
| `Typeahead` (`typeahead`) | only by stored key: an `autocomplete` from snapshot.js `typeahead` (ARIA-less) | `Autocomplete#write` with `MAX_WAIT = 3`; no suggestion at all (`Mismatch`) → `fill(value)`: a plain text field after all | - | the picked label, else the typed value | `:click` |
| `NativeSelect` (`native_select`) | select | `MatchOption` → `select(label:)` of the matched option; none (or several) → `Mismatch` before any select call (Playwright would time out on a missing label) | `select(value:)` of the matched option | selected text == option label | `:key` |
| `OptionGroup` (`option_group`) | radio_group, option_group, checkbox_group | `MatchOption` over the group's choices (from `probe(:snapshot, root)`), click the label / button / `role` option (unpicked ones only for multi) | - | the checked / `aria-pressed` choice names == the wanted labels, not invalid | `:click` |
| `NativeCheck` (`native_check`) | checkbox | `set_checked` on the visible label when there is one, else the input (`:attached`) | - | `checked` == `MatchOption.truthy?(value)` | `:click` |
| `DateInput` (`date_input`) | date | the answer parsed to a `Date` (ISO first, then `Date.parse`; unparseable → `Mismatch` before any write); `type=date/month/week/datetime-local` (read_value `type`) → `fill` in the native format (`YYYY-MM-DD` for date); a masked text input → the placeholder mask (`dd` `mm` `yyyy` `yy` tokens, `MASK`; default ISO), `fill('')` + `type` | - | the read value equals the formatted date, or parses (mask format, then `Date.parse`) to the same date | `:key` |
| `Range` (`range`) | range | number from the answer (else `Mismatch`); `min` / `step` from `probe(:read_value)` (`min`/`max`/`step`, `aria-valuemin`/`aria-valuemax`); click, `press('Home')`, `press('ArrowRight')` × `((value - min) / step).round` clamped to `0..MAX_STEPS = 200` | `fill` on a visible companion `input[type=number]` in the field root (or the control's parent) | `value`, else `aria_valuenow`, as a number == wanted | `:key` |
| `ContentEditable` (`content_editable`) | rich_text | click, `press('Control+a')`, then `type` in the `:submit` scope (≤ `TYPE_LIMIT`, like Text) else `fill` (Playwright fills a contenteditable) | `fill` | the element's text (squished) == wanted | `:key` |
| `Text` (`text`) | text, email, tel, url, number, textarea | `fill`; in the `:submit` scope `fill('')` + `type` (jitter) for values ≤ `TYPE_LIMIT = 300` chars | `fill('')` + `type` | value (squished) == wanted (catches `maxlength` cuts) | `:key` |

Kinds with no driver (`multiselect`, `hidden`) → `no_widget_driver` when they must be filled. **Approximate pick**: only
`Autocomplete` sets one; `FillFields` stores it at once as the answer `{ value: <label>, source: 'approximate',
confidence: 0.5 }` (`ctx.persist!(answers:)`, so a later halt cannot lose it), and `approximate` is a safety review
reason, so the stage halts `review` before the claim whatever `review_policy` says (design §7.4).

**FillFields** (`Stage::FillFields`, key `fill`, design §7.4) fills the form page by page (a wizard has several),
always before the claim. It copies `apply.cv` into a temp dir (removed in `cleanup`, also on halt) for `FileRef.cv`
answers. Page 1 = `platform.fill_order(ctx.fields)` of the fields with a target (ReconcileFields keeps the stored
fields of later pages without one). Then at most `MAX_WIZARD_PAGES = 6` times:

1. **Fill the page**: every `fillable?` field not already filled (or left unfilled) on an earlier page — a field is
   never filled twice: no answer → skip, or `Halt(:required_field_unfillable, detail: id)` when required; in the DOM
   but not shown (`Session#present?(target, visibility: :required)` false: a CSS-hidden later step, a display:none
   honeypot; a file input is exempt) → not written, offered again on the next page; `SetFieldValue`; `Mismatch` → `RecoverField` (any AI integration); still a `Mismatch` → required:
   `CaptureArtifact(label: :unfillable)` on `ctx.scratch.step_record` (masked screenshot) and the same halt;
   optional: trace `unfilled` and go on. An approximate pick is persisted as above.
2. **Review**: `Answer::ReviewRequired` → `Halt(:review)`. It runs on every page, so a follow-up answer that needs a
   review (low confidence, approximate, a safety reason) halts BEFORE the Next click of its page and before the claim
   (design §8.2). After `ApproveReview` the submit scope replays the pages from the stored answers: the follow-up
   fields keep their ids, so nothing is asked again.
3. **`Engine::ClassifyAdvance`** (see Submit and Verify): `nil` → `Halt(:target_not_found, detail: 'no submit or next
   button in the form')`; `:final` → a stored required fillable field that never had a target in this session and was
   not filled → `Halt(:target_not_found, detail: id)` (the wizard changed under the stored answers); one that was in
   the DOM but never shown (`Session#present?(visibility: :required)` false on every page: a CSS-hidden step that
   never opened) → the unfilled-required halt (`CaptureArtifact(label: :unfillable)`,
   `Halt(:required_field_unfillable, detail: id)`); optional never-shown ones are traced `hidden_unfilled`; else return
   (Stage::Submit clicks the `:final` button after the claim); `:next` on page `MAX_WIZARD_PAGES` →
   `Halt(:wizard_too_long, detail: 'more than 6 pages')` without clicking. ClassifyAdvance runs on a fresh
   `FormElements.snapshot`, which also gives the page key used in step 4.
4. **Next page** (`:next`): `GuardAction { session.click(advance.target) }` → `ctx.scratch.wizard_page = page` →
   `settle(:click)` → fresh
   `FormElements.snapshot` → `RunGates(:after_action, snapshot:)` → `Engine::AnswerFollowups.call(ctx:, page:,
   snapshot:)` gives the page's fields; trace `wizard_page` (`page`, `button`, `fields`).
   **A Next that does not advance**: the page key is `[form frame URL, SnapshotAll.digest_of(form elements) (the
   Navigator's ONE page-state digest: fingerprint + visible/expanded/selected/pressed/checked/disabled, no values),
   form frame outline without "dialog …" lines]`. If the key after the click equals the key before it, FillFields
   runs one more `settle(:click)` and takes one more snapshot (a slow transition). If the key is still the same, the
   site refused the page: a JS or server check the read-back never sees, such as "email already registered" or a
   custom error without `aria-invalid`. FillFields traces `wizard_stalled` (`page`, `button`) and halts with
   `Halt(:validation_rejected, detail: "next did not advance: <form-frame alerts | invalid: <name>>")`
   (`MAX_STALL_DETAIL = 300`), before any claim. It never clicks the same Next again until `wizard_too_long` (which is
   `unsupported`, a terminal state).

`Engine::AnswerFollowups` (design `ctx.answer_followups!` / `inventory.discover_new!`): `BuildFieldInventory` on the
snapshot, `ReconcileFields(stored: ctx.fields, fresh:, strict: false)` (a known field present now takes its fresh target
under its stored id; earlier pages' fields stay without a target instead of halting; one implementation of the
matching), unmatched fresh fields are new and get `page:` (`Field#later_page?`). New fields →
`ctx.scratch.followup_calls += 1`, over `MAX_FOLLOWUP_ANSWER_CALLS = MAX_WIZARD_PAGES + 2 = 8` →
`Halt(:wizard_too_long, detail: 'follow-up answers')`; the new fields without a stored answer (an earlier attempt's
follow-up or a review edit is reused) go through ONE `Answer::Resolve.call(ctx:, fields:)` (`CallAi`, inside the submit
lease; `ExtractFacts` is not called); `ctx.persist!(answers: merged, fields:)`. Trace `wizard_fields`. Model = the
fields on the page now, in `fill_order`.

Termination when the world stays broken: a Next that leaves the page key unchanged halts at once (≤ 2 snapshots); at
most `MAX_WIZARD_PAGES` pages (≤ 5 Next clicks), finite fields per page,
≤ `MAX_FOLLOWUP_ANSWER_CALLS` follow-up AI calls (each also counted by `CallAi`'s per-attempt budget), the scope
deadline over all of it. step_result `{ filled: n, unfilled: [ids], pages: n }`.

Adding a driver: a class under `apply/widget/` with `handles?(field)` and `write`, override `read` /
`expected_display` / `accepts?` / `fallback_write` / `settle_kind` / `approximate_pick` as needed, add it to
`Registry::DRIVERS` at its precedence (`registry_spec` checks every file is listed), and a `:browser` spec on a fixture
page asserting the read-back (`spec/support/fixture_site/pages/widgets.html` holds the custom controls).

### Field recovery

`Engine::RecoverField.call(ctx:, field:, value:, mismatch:)` (design `Engine::FieldRecovery`, §7.3 O7), called by
`FillFields` after `SetFieldValue` raised `Mismatch` (write and fallback both failed). Per turn, at most `MAX_TURNS = 2`:

1. `snapshot_all(regions: [field root css])`; the root is the target's own `root`, else the `root_strategies` of the
   element the `before` snapshot shows at the target's css path, else the control itself. Usable elements: visible ones
   in the field's frame inside that root, plus elements NEW since the write (fingerprint absent from `mismatch.before`)
   in the field's frame or the top document (portaled menus, marked `*` in the prompt).
2. `CallAi` (`Prompt::RecoverField`, `ResponseSchema::RecoverField`, `requires: %i[json_schema]`, timeout = what is left
   of `MAX_SECONDS = 30`, clamped to `ctx.remaining`; a turn needs `CallAi::MIN_TIMEOUT` left). `give_up` → stop.
   Invalid output → the error goes into the next turn's prompt.
3. Each action (`click` / `press` only, ≤ 3): a ref outside the usable set → rejected without touching the page (trace
   `action_rejected`, reason `outside_field`); else `ExecuteAction(allowed: %w[click press])` (its validator rejects
   submit_like / password / Enter in a control). Stops after an action that navigated.
4. At least one action performed → `SetFieldValue` again: accepted → model = its ReadBack (trace `field_recovered`,
   `result[:approximate]` passed through); another `Mismatch` → the next turn.

Termination when the field never takes the value: `MAX_TURNS` AI calls (each counted by `CallAi` against the AI budget),
the `MAX_SECONDS` monotonic budget, or `give_up`; then the LAST `Mismatch` is raised again (trace `field_unrecovered`).
The value never reaches the AI (the prompt shows `<filled>` / `<empty>` only, never the answer or the read-back text).
`FillFields` turns a required field's final `Mismatch` into an `unfillable.png` artifact (masked) on the step row plus
`Halt(:required_field_unfillable, detail: field.id)`.

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
3. `Engine::ClassifyAdvance.call(ctx:, snapshot:)` — the one locator, shared with FillFields' wizard loop: `nil` →
   `Halt(:target_not_found)`; `:next` → `Halt(:wizard_too_long, detail: 'next button at submit')` (FillFields must
   have consumed every page); `:final` → its target. The rule:
   - Candidates: visible, enabled `FormElements` of the form root that are `submit_like`, plus — only when the page
     shows evidence of a further page — buttons (`button`, `role=button`, `input[type=submit|button|image]`, not an
     option-group choice) named by `NEXT_LEXICON` (a wizard's Next is often `type=button`, which the probe never
     calls `submit_like`).
   - No such candidate → the form's buttons named by `FINAL_LEXICON` (a dialog footer's `type=button "Відгукнутися"`
     outside its `<form>`): inside the form root an apply / respond verb is the final button; outside it the same word
     is the page's launcher, so `SnapshotAll::SUBMIT_TEXT` (and `submit_like`) never carries it.
   - Still none → `#dialog_finals`: the form root's nearest dialog / modal container (`probe(:anchor, form_root)`
     `container`: `dialog`, `role=dialog|alertdialog`, `aria-modal`, `.modal`), one more `snapshot_all(regions:
     [container, *excluded_regions])`, and its visible, enabled `submit_like` / `FINAL_LEXICON` buttons in the root's
     frame (an Angular uib-modal keeps `type=button "Відгукнутися"` in `.modal-footer`, a sibling of `.modal-body >
     form`). No container → none. The Advance target of such a button gets `{ css: "<container> <tag>", has_text:
      name }` first (`<button>` / `<a>` only): the snapshot's `{ role, name }` also matches a `role=button` host and the
      page launcher, and its absolute nth-of-type path breaks when the modal sits at another body index.
   - One candidate → it. Several → the one `NEXT_LEXICON` names when there is evidence of a further page, else the one
     `FINAL_LEXICON` names, else `Halt(:target_not_found, detail: "submit buttons in the form: n")`.
   - `kind = :next` ONLY when the chosen name matches `NEXT_LEXICON = /\A\s*(?:next|continue|далі|продовжити|
     наступн\p{L}*|далее|weiter)\b/i` AND there is evidence of a further page; anything else is `:final` and goes
     through the claim (a click that might submit is never taken as a Next). `FINAL_LEXICON =
     SUBMIT_TEXT ∪ SnapshotAll::APPLY_TEXT`.
   - Evidence (looked up only when some form button carries a `NEXT_LEXICON` name): `STEP_INDICATOR =
     %r{\b(?:step|крок|шаг|page|сторінка)\s*(\d+)\s*(?:of|з|из|/|від)\s*(\d+)}i` with `0 < k < n` in the form
     root frame's outline or in `FormElements.visible_text(ctx)` (the root's visible text, the same reader
     `CollectSubmitEvidence` uses; it skips text under `[hidden]` and inline `display:none`) — but no step evidence
     at all when any indicator found shows `k >= n` (indicators that disagree: a wizard keeping every step in the DOM
     and hiding the others by CSS classes, which a parse cannot see; the doubt goes to `:final`); a
     `progressbar <now>/<max>` outline line with `now < max`; or a required, unconditional (`condition` blank)
     `ctx.schema` field still ahead: no `ctx.fields` entry at all, or a stored follow-up field without a target whose
     `page` is after `ctx.scratch.wizard_page`. An earlier page's field has lost its target (`ReconcileFields(strict:
     false)`) but is behind, never evidence — otherwise a last-page "Continue" that really submits would be taken as
     a Next and clicked without the claim.
   - Traced `advance` (`kind`, `name`, `evidence`, e.g. `['step 1/2']`).
4. `GuardAction` around `session.trial_click(button)` (actionability only, no click): an overlay that would swallow
   the click halts as `target_obstructed` with the claim untouched.
5. `session.network_watch(success_evidence[:submit_request][:url])` — registered BEFORE the click, so NetTracker reads
   the response body.
6. `CaptureArtifact(:before_submit)` (never raises) → `ctx.scratch.submit_baseline = SubmitBaseline.call(ctx:).model`
   (the page signals that already hold, see Baseline below; before the claim, so a browser error here is resumable)
   → `ClaimSubmit` → `ctx.scratch.claim_mark = session.network_mark` → `session.click` → `settle(:submit)` →
   `RunGates(:after_submit)` on a fresh snapshot.

**`Stage::Verify`** (key `verify`) → `Engine::VerifySubmit.call(ctx:)` → `Verdict(status, evidence)`:

- **Wait**: one `session.wait_until(timeout: ctx.clamp(EVIDENCE_WAIT = 20))` re-collects the evidence (without field
  probes) until the deterministic signals reach `min_signals` or a `failure_selectors` element shows. Needed because a page may send its request well after
  the click (reCAPTCHA token first; ~1.2 s on the fixture), past `settle(:submit)`'s quiet window. Then one full
  `CollectSubmitEvidence`.
- **Evidence** (`CollectSubmitEvidence::Evidence(text, urls, requests, in_flight, success_dom, failure_dom, form_present,
  field_errors)`, called with `success_selectors:` / `failure_selectors:` from `success_evidence`): the visible text
  (text nodes joined by spaces, no script / style) of the form root FIRST, then the rest of that frame's body (a
  confirmation may render beside the root or replace it), ≤ `TEXT_LIMIT = 4_000`; `current_url` + frame URLs;
  `network_since(claim_mark, bodies: true)` (records carry `body` and `body_error`); `in_flight` =
  `network_in_flight(claim_mark)`; `success_dom` / `failure_dom` = the given selectors present in the form root's frame
  (the Nokogiri document already parsed, no extra browser call); `form_present` =
  the root still holds controls; `field_errors` = `read_value` `invalid` / `error_text` of up to `MAX_FIELD_PROBES = 50`
  known fields (only when the form is present).
- **Signals**: `success_text` (a `texts` regex in the text), `success_dom` (any `selectors` element present),
  `url_match` (a `url_patterns` regex on a URL), `submit_request` (a 2xx request matching the URL regex whose body
  passes `body_ok.(JSON.parse(body))`; a parse error counts as false). Decision: a 2xx whose body could not be read
  (`body_error` `dropped` / `unreadable` / `timeout`) does NOT count — a GraphQL API answers 200 to a rejected submit
  too (Ashby `FormRender`), so only the body proves acceptance; the summary records why it was missing. Success text
  alone never satisfies a `min_signals: 2` platform (Generic). AI (`Apply::Ai::Prompt::VerifySubmit` on the `Redact`ed text inside untrusted markers,
  `ResponseSchema::VerifySubmit`, kind `:verify`) is asked only when the deterministic count is > 0 and exactly one
  short of `min_signals`, with any AI integration (text mode and `browser_backed` included) and never while vetoed; it counts
  +1 only with `submitted: true`, `confidence >= AI_MIN_CONFIDENCE = 0.8` and its `quote` found in the text. An AI
  verdict alone never counts.
- **Baseline**: the page signals (`VerifySubmit::PAGE_SIGNALS` = `success_text`, `success_dom`, `url_match`;
  computed by `VerifySubmit.page_signals(spec, evidence)`, the one implementation) that already held BEFORE the click
  never count. `Engine::SubmitBaseline` runs `CollectSubmitEvidence(field_errors: false)` in Stage::Submit right
  before `ClaimSubmit` and stores the names that held in `ctx.scratch.submit_baseline` (e.g. `['success_text']` for
  an intro "Thank you for your interest", `['url_match']` for a `/success-stories/` path). VerifySubmit counts a page
  signal only when it is true now AND absent from the baseline (the wait loop uses the same rule); `submit_request`
  has no baseline (requests are read since `claim_mark`). A nil baseline (Verify without a Submit in the run) holds
  nothing.
- **Status**: a **veto** = a `failure_dom` element (a "could not submit" view) or the form still present with field
  errors. Count ≥ `min_signals` and no veto → `:submitted` (Verify attaches a masked full-page screenshot to
  `apply.screenshot`, a failing screenshot is traced; Finish completes the run). Else a veto + nothing still in flight
  since the claim + every request since the claim answered 4xx (none at all also qualifies) → `:rejected` →
  `Halt(:validation_rejected, definitive: true, detail: "field errors: <ids>; <Verdict#detail>")` (releases the
  claim). A pending request, a transport failure (`status` nil), a 2xx (Ashby answers 200 behind its failure view),
  3xx or 5xx may mean the server took it, so the claim is kept. Else `:unknown` →
  `Halt(:outcome_unknown, detail: Verdict#detail)` → `submit_unverified` through the claim rule. Trace `verdict` holds
  the evidence summary.
- **Diagnostics**: the summary (`Verdict#evidence`) holds `signals` (per-signal booleans after the baseline, incl.
  `ai`), `count`, `min_signals`, `baseline`, `form_present`, `field_errors` (ids), `requests`, `mutations_2xx`, `in_flight`, `success_dom`,
  `failure_dom` and `submit_op` (nil when the platform names no submit_request, else one `{ status, body }` per request
  matching its URL, `body` ∈ `ok` / `not_ok` / `dropped` / `unreadable` / `timeout` / `none`). `Verdict#detail` is that
  on one line, e.g. `signals 1/2 (success_text=no success_dom=yes url_match=no submit_request=no ai=no); baseline []; requests 14,
  2xx 14, in_flight 0; submit_op [200 dropped]; form_present no, field_errors 0; success_dom [...], failure_dom []`; it
  becomes `apply.failure.detail` / the step's `error_detail` (through `Redact`), and every non-submitted verdict logs
  `apply=<hashid> verify <status>: <detail>` at warn, so a failure stays diagnosable after its artifacts are pruned.

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
6. **Успіх.** `success_evidence` (тексти, URL-патерни, `selectors` екрана підтвердження, `failure_selectors`,
   `submit_request` з `body_ok`, URL якого називає саме submit-операцію); `min_signals: 2`. Текст підтвердження
   компанії можуть змінювати — потрібна пара сигналів, що від нього не залежить (DOM-маркер + відповідь мутації).
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
    як Generic через Navigator.

## Smoke survey (read-only)

Dev/staging tooling to check a live application form without applying. Point it at a **throwaway** queued apply: the
survey ends it in `cancelled`.

```bash
BROWSERD_URL=http://localhost:9300 bin/rails 'apply:smoke[<apply hashid>,https://dou.ua/goto/vacancy/?id=375494]'
```

`lib/tasks/apply.rake` → `Apply::Operation::SmokeSurvey.call(apply:, entry_url:, out: $stdout)` (`skip_authorize`):
`StartContext` on the given apply (must be startable: queued / waiting_capacity / stale running) →
`Stage::DetectPlatform` (the `entry_url` argument overrides `applies.entry_url` / the vacancy's `external_url`) →
`Stage::FetchSchema` → ONE `Session.open(humanize: false)` lease running `Stage::ReachForm` (for an unknown platform
the [Navigator](#navigator-generic): it may click, press, scroll, switch tabs and follow links to REACH the form, never
types or submits) and, whenever a form root was set (Generic included), `Stage::DiscoverFields`. It prints platform,
confidence, probable, captures, HTTP hops, schema field count, canonical URL, navigation ops (`navigation:`), the
navigator line (`navigator: <n> action(s), form reached yes|no`: `navigate` trace events), the attempt's AI calls
(`ai calls:` = `apply.reload.ai_calls`), form URL and its frame, the ReachForm time (readiness), any halt (a gate that
fired, the Navigator giving up) and the field table (id, kind, widget, label, required, options count, frame). The
report hash adds `form_reached`, `ai_calls` and `navigator_actions`. The Navigator spends real AI calls of the throwaway
apply (`ai_calls_total` counts them). Finally one
`FencedUpdate` ends the apply in `cancelled` (`stage: nil`, `run_token` rotated) with the engine columns the stages
wrote (`SmokeSurvey::RESTORED_COLUMNS`: platform, platform_match, apply_key, entry_url, landing_url, fields, form_url, navigation)
restored; no `apply_steps` rows are written (the Runner is not involved), `attempt` keeps its +1.

Never back to `queued`: `queued` is an `IN_PROGRESS_STATES` member, so `ReapStale` would find the row after
`STALE_AFTER` (verdict lost -> auto-resume -> `Engine::Enqueue`), or the job `Create` enqueued would start it, and the
full engine would fill and **submit** (default `review_policy: never` + `auto_consent: true` pass `ReviewGate`).
`cancelled` is not startable (`StartContext` refuses it) and the rotated token fences a job already in flight
(`smoke_survey_spec.rb` asserts both). Create a new apply to apply for real.

It never answers, fills or submits: no other stage is referenced (`smoke_survey_spec.rb` asserts no fill/type/select/
check/upload/press call and no `ClaimSubmit`, for a known platform and on the Generic Navigator path). Known limit: a
Navigator click on a `type=submit` button of a form with no visible fields (not `submit_like`) would let the browser
submit that form; the survey has no browser-level POST block. The run's HTTP client (`ctx.scratch.http`) is
`ApplyMate::Client::ImpersonateHttp::ReadOnly`: every Ruby-side POST raises `RequestError` before curl runs, so the
adapter's `fetch_schema` (for Ashby the `ApiJobPosting` GraphQL POST) is traced `schema_unavailable`, the report shows
`schema api: 0` and the field table comes from the DOM. Network side effects are the GETs of the redirect walk, the
page loads (and whatever the page itself requests on a normal visit) and CookieConsent clicks. The Runner's `Heartbeat` ticker runs for the whole survey and is shut down before the cancelling write: the row is
`running` with no Solid Queue job behind it, and the Navigator alone may take `MAX_SECONDS` (180 s = `STALE_AFTER`)
plus its slow-AI allowance, so without the beat `ReapStale` would judge a long survey lost and auto-resume the full
engine on the throwaway row (`smoke_survey_spec.rb` asserts the ticker runs and is shut down).

## Redactor

`Apply::Operation::Engine::Redact.call(text:, apply: nil, max_length: MAX_LENGTH).model` — the only redactor (failure.detail, step
error_detail, step result / trace through `RedactTree`, artifact HTML). Nil-safe, symbols are stringified, output truncated to `max_length` (default `MAX_LENGTH = 2_000`).

| Category | Result |
|---|---|
| `Cookie:` / `Set-Cookie:` / `Authorization:` lines | line dropped |
| credentials, via `ApplyMate::Ai::Client::Base.scrub` (the one credential scrubber, also used by the AI clients): `key= api_key= apikey= x-api-key= signature= sig=` and any `*token=` (`access_token=`, `id_token=`, `csrftoken=`) values; a provider error's URL carries Gemini's `?key=` | `name=[REDACTED]` |
| bare Google API keys (`AIza[0-9A-Za-z_-]{35}`, e.g. in a header or JSON) | `[REDACTED]` |
| `csrfmiddlewaretoken= sessionid= code=` values (`SESSION_PARAM`) | `name=[REDACTED]` |
| the apply's `source_profile.session_id`, `user.email` (>= 6 chars) | `{{fact.session_id}}`, `{{fact.email}}` |
| any other email | `{{email}}` |
| phone-like digit runs (`\+?\d[\d\s().-]{8,}\d`) | `{{phone}}` (also hits long ids / dates, on purpose) |

## User operations

The user acts on an apply through six operations (`Apply::Operation::Resume`, `Cancel`, `MarkOutcome`, `ApproveReview` (see "Answers and review"), `ProvideInput`, and `Destroy`). All load the record with `policy_scope(Apply).find`, so another user's apply is a 404, then authorize with `resume?`/`cancel?`/`mark_outcome?`/`approve_review?`/`provide_input?` (owner only). Each transition is one state-guarded `UPDATE` (`update_all ... WHERE id AND state IN (...)`): 0 rows means a concurrent run, claim or cancel won, and the user gets the `not_allowed` error. After a transition they `touch_user_applies_changed_at!` (navbar counter key), broadcast through `Engine::Broadcast`, and answer with a notice. The controller renders only a flash turbo stream; the cards refresh through the broadcast.

| Operation | Allowed from | Writes | Refused when |
|---|---|---|---|
| Resume | `failed`, `unsupported`, `needs_human` with `submit_claimed_at` NULL and no submitted sibling (`Apply#resumable?`) | `queued`, `stage` NULL, then `Engine::Enqueue` | `submit_unverified`, claimed `needs_human`, another apply for the vacancy already active (`already_active`), another non-cancelled apply for the vacancy already claimed or submitted (`already_submitted`) |
| Cancel | `Apply::CANCELLABLE_STATES`: `queued`, `needs_human`, `failed`, `unsupported`, `needs_review` | `cancelled`, `run_token` rotated, `stage` NULL | `running` (wait for finish or the reaper), `submit_unverified` (resolve through MarkOutcome) |
| ProvideInput | `running` and `stage = 'awaiting_input'` with an open `input_request` | `input_response` `{code, at}` (code trimmed, 1..`MAX_CODE_LENGTH` = 32 characters) | any other state (`not_allowed`), blank or long code (`invalid_code`) |
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

1. Re-apply: `Apply.reapply_guarded` (a prior apply that claimed or submitted, not cancelled) needs `confirm_reapply=1` (a virtual form property), else `reapply_confirmation_required`.
2. A second active apply for the vacancy is rejected by the real partial unique index `index_applies_one_active_per_vacancy`: `RecordNotUnique` becomes `already_active`.

On success it calls `Engine::Enqueue` (stores `job_id`) and touches the user's counter key.

## Attention inbox

`GET /applies?filter=attention` returns `Apply.attention` rows (`ATTENTION_STATES`), riding `index_applies_on_user_state`. `Apply::Operation::Index` exposes `ApplyMate::Operation::Struct(applies:, filter:, attention_count:)`; the count is `Apply.attention_count_for(user)`, cached under a key that changes with `users.applies_changed_at`. Unknown filter values are ignored.

## Artifacts

Stored files (Apply `cv`/`screenshot`, VacancyCv `cv`, ApplyStep `artifacts`) are never linked through permanent blob URLs. `GET /artifacts/:owner/:id/:name` (`artifact_path(owner:, id: hashid, name:, disposition:)`, owner `apply|vacancy_cv|apply_step`, name `cv|screenshot`, or the 1-based artifact position for `apply_step`) runs `Artifact::Operation::Show`, which resolves the record through `policy_scope`, authorizes `show?`, checks the name against the owner table (`OWNERS`; `apply_step` has `names: :artifact_at` and `name` is the 1-based position of one of the step's `artifacts`, resolved by `ApplyStep#artifact_at`) and answers a 5-minute presigned storage URL (`inline`, or `attachment` for `disposition=attachment`; an HTML snapshot, `Show::DOWNLOAD_ONLY`, is always `attachment`, so it is never rendered on our origin). `ArtifactsController` redirects to it with `allow_other_host: true` (minio is another host). Unknown owner/name or a missing attachment is a 404. The design names this `Apply::Operation::ShowArtifact` / `ApplyArtifactsController`; one generic operation was chosen so `VacancyCv` (rendered by the same `CvContent` component) needs no second copy.

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
hides for code `review` while the form shows. `ActionBox` shows a "Переглянути" link to the card instead.
`InputRequest` (`apply.input_request.*`, mounted in `VacancyApplyCard` right after `FailureNotice`) is the code box of
`Engine::AwaitInput`: it renders only for a `running` apply in stage `AwaitInput::STAGE` (`awaiting_input`) with an open `input_request` and no
`input_response`, as an amber card with the title/hint for the request `kind` (`email_code`, else the `generic` texts),
the expiry (`input_request['expires_at']`) and one `code` input (`autocomplete=one-time-code`, `inputmode=numeric`,
`maxlength` = `ProvideInput::MAX_CODE_LENGTH`) posting to `provide_input_apply_path` as `turbo_stream`. It takes only
`apply:`: it reads nothing of the user. No extra stream: `AwaitInput`'s `Engine::Broadcast` makes `StatusUpdate` re-render the whole card, and
the pill shows the `apply.stage.awaiting_input` text. `running` is not an attention state, so the navbar counter and the
attention filter do not count `awaiting_input`. The navbar counter and the "Потребують уваги" filter share `Apply.attention_count_for`.
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
- **No recipe learning yet** (phase 6). The submit scope replays `applies.navigation` through `Recipe::Interpret`
  (all seven ops; phase 3b); in 3a it re-reached the form the survey's way.
- **The CV stage is `Ai::GeneratePdfCv`**, reused unchanged (key `generate_cv`, no input digest: it re-runs on a
  resumed attempt).
- **`Apply::Handler::Djinni` untouched** (phase 4). In 3a Handler::Dou kept a legacy browser path for platforms the
  registry did not know; phase 3b deleted it (every external apply runs the engine).
- `Apply::Field` is `class Apply::Field < Data.define(...)` (constants inside a `Data.define` block would land on
  Object).
- `FixtureAshby` (spec) keeps the key `ashby` instead of `fixture_ashby`: schema ids (`ashby:<path>`) and
  `Context#schema_keys` derive from the key; only `origin` (and the signals built from it) is overridden.
- `ResolvePublicAddress` pins the first IPv4 answer (else the first answer): an IPv6 pin on an IPv4-only host made
  every pinned fetch fail. All answers are still checked public.
- Stage restores read the unredacted `applies.platform_match` / `applies.landing_url` / `applies.form_url`: stored step results go through
  `RedactTree`, whose phone rule rewrites UUID digit runs.

## Deviations from the design (phase 3b)

- **No `Recipe::Compiler` / `RecipeStore`** (phase 6): the Navigator's performed actions ARE the stored recipe.
  `applies.navigation` is a plain Array of op hashes (`Recipe::Op::*#to_h`), no `Recipe::Definition` class: the
  landing `goto` (`url_template: '{landing_url}'`, never a literal URL), the ops that moved the page, and a terminal
  `wait_for` (form root selector, frame path, `min_fields`) that replays readiness. `fill` is not an op.
- **`navigate` is recorded as a `click`** on the link the AI named (the design's compiler would store a URL template;
  a literal URL never reaches `applies.navigation`).
- **No screenshots in prompts**: `:vision` images are not sent to the Navigator, `RecoverField` or `VerifySubmit`;
  every prompt is text (element lines, outline, untrusted-content blocks).
- **Approximate picks come from the widget**: `SetFieldValue` returns `result[:approximate]` (an Autocomplete / combobox
  option that only resembles the answer); `FillFields` stores it as an answer with source `approximate` and confidence
  0.5, so the run halts for review before any claim. There is no separate "approximate" classifier.
- **The design's PORO names are operations** (`Engine::Navigate`, `ExecuteAction`, `AssessFormLikeness`,
  `CheckOrigin`, `ClassifyAdvance`, `RecoverField`, `AwaitInput`, `Recipe::Interpret`), per "Operations, not POROs".
- **No integration is refused** (owner decision 2026-10-09, overriding §18 item 8): a browser-backed client
  (GeminiScraping) drives the Navigator in text mode, under the one-Chrome slot ("Latency-aware budgets and the
  local Chrome slot").

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
- `spec/concepts/apply/job/apply_e2e_spec.rb` runs Job -> Handler -> Runner on the honeytech DOU context (PeopleForce
  as Generic on a scripted FakeSession: Navigator, claim, verify; step rows, idempotent re-run, zombie writes nothing,
  `job_id` stored by `Enqueue`).
- `spec/support/snapshot_builder.rb` (`build_snapshot(frames:, elements:)`, `snapshot_element(...)`) builds a real
  `Snapshot` through the production `SnapshotAll` from canned probe output; FakeSession's `snapshot:` / `show(snapshot,
  url:, html:)` script the pages a Navigator / stage spec walks through. The 'honeytech dou' context
  (`spec/support/shared_contexts/honeytech_dou.rb`) has the PeopleForce form snapshot and the Gemini router
  (`stub_gemini_router`, `gemini_route(text)`: Navigate answers use refs parsed from the prompt; `rspec.md`).
- `spec/concepts/apply/handler/dou_ashby_browser_spec.rb` (`:browser`) runs Job -> Handler::Dou -> Runner on the real
  browserd-test against FixtureSite's Ashby pages (`FixtureAshby`, `stub_fixture_ashby_registry`,
  `FixtureSite.on_submit`; `rspec.md`): full run with one POST and the claim before it, the `review_policy: always`
  resume, and the Google Forms redirect (`needs_human`, no lease).
- `spec/concepts/apply/handler/dou_generic_browser_spec.rb` (`:browser`) is the Generic end to end on FixtureSite's
  `generic/careers.html` + `generic/widget.html` (no adapter): the AI router clicks the "Apply" tab inside the
  cross-origin iframe, claims the form, the 2-page wizard is filled with read-back (Element-UI-like select,
  contenteditable cover letter, file, consent), Next is classified `:next`, "Submit application" `:final`, the claim
  precedes the single `POST /generic/submit` (`FixtureSite.on_submit`), verify needs the thank-you text + the AI.
  The `review_policy: unknown_platforms` example replays the stored navigation without a Navigate call.
- `dou_spec.rb` covers the routing without a browser (external = engine on the PeopleForce FakeSession, including a
  GeminiScraping integration in text mode; internal; step-key uniqueness).
- `spec/concepts/apply/operation/smoke_survey_spec.rb`: SmokeSurvey on a FakeSession (report, no fill/claim, apply
  ended `cancelled`, the Generic Navigator path, Google Forms halt without a lease).
