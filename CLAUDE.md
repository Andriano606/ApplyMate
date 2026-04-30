# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

# ApplyMate

Rails 8 + Hotwire (Stimulus + Turbo) job-application automation app. Users find vacancies via Elasticsearch, then the app automates fetching vacancy details, generating a tailored CV, and submitting the application via browser automation (Ferrum + Chrome).

## Essential Commands

```bash
bin/dev                                          # Start all dev processes (Rails + JS/CSS build + Caddy)
bundle exec rspec spec/path/to/file_spec.rb      # Run a single spec file
bundle exec rspec spec/concepts/                 # Run all operation specs
bundle exec cucumber features/path/to/file.feature
```

## Architecture: Concepts

All business logic lives in `app/concepts/<resource>/`. Each concept can have:

- **`operation/`** — plain Ruby service objects. Controllers call exactly one operation per action. Operations inherit `ApplyMate::Operation::Base`, implement `perform!(params:, current_user:, **)`, call `authorize!` (Pundit) or `skip_authorize`, and set `self.model =` with the result.
- **`component/`** — ViewComponent classes (`ApplyMate::Component::Base < ViewComponent::Base`). Templates are `.html.slim` files beside the `.rb` file.
- **`form_object/`** — `ApplyMate::FormObject::Base` wraps params before syncing to AR models. Use `.property`, `.has_many`, `.has_one`. Call `parse_validate_sync(form_object, model)` inside an operation to validate and sync.
- **`turbo_handler/`** — real-time broadcast helpers. Inherit `ApplyMate::TurboHandler::Base`; implement `stream_from`, `frame_tag`, and `broadcast` (calls `Turbo::StreamsChannel.broadcast_action_to`).
- **`job/`** — ActiveJob classes scoped to the concept.

`apply_mate/` holds shared base classes for all of the above.

## Request Flow

Controllers call `endpoint(OperationClass, ComponentClass)` (defined in `OperationsMethods` concern), which:
1. Calls the operation with `params:` and `current_user:`.
2. Verifies Pundit authorization was called (raises otherwise).
3. Dispatches to `ApplyMate::Endpoint::Html` or `ApplyMate::Endpoint::TurboStream` based on `Accept` header.
4. On success: renders the component or redirects. On failure: re-renders the form component with errors.

```ruby
# Typical minimal controller
class AppliesController < ApplicationController
  def index
    endpoint Apply::Operation::Index, Apply::Component::Index
  end
  def create
    endpoint Apply::Operation::Create, Apply::Component::NewModal
  end
end
```

Custom success/failure handling: pass a block to `endpoint` and use `m.success` / `m.invalid`.

## Key Conventions

- Default locale is **Ukrainian (`uk`)** — use `I18n.t()` (full form, NOT `t()`)
- All UI must be **responsive** (mobile-first), styled with Tailwind utility classes in Slim templates
- IDs in URLs use `hashid` (via `hashid-rails`), never bare integer IDs
- Operations **must** call `authorize!` or `skip_authorize`; forgetting raises at runtime
- `notice(I18n.t('...'))` inside an operation sets the flash message returned via result

## Key Gems

| Gem | Role |
|-----|------|
| `elasticsearch-model` | Full-text vacancy search; `Vacancy` has ES mappings and `as_indexed_json` |
| `pundit` | Policy-based authorization — one `*_policy.rb` per model |
| `view_component` | Component rendering |
| `simple_form` + `slim-rails` | Forms in `.html.slim` templates |
| `dry-matcher` | `Matcher::MatcherWithDefaults` used by Endpoint for success/invalid dispatch |
| `ferrum` | Headless Chrome via CDP for scraping/form-filling |
| `solid_queue` + `solid_cable` + `solid_cache` | Background jobs, ActionCable, caching |
| `grover` + `redcarpet` | Markdown CV → PDF pipeline |
| `will_paginate` | Pagination; operations return `WillPaginate::Collection` |

## Stimulus Controllers

All controllers registered in `app/javascript/controllers/index.ts`. Notable ones:
- `turbo-form` — augments forms for Turbo Stream submission; supports real-time updates on change (AbortController-based)
- `turbo-modal` — manages modal open/close lifecycle; nested modal support (parent hidden, child removed)
- `search-tags` — tag-pill input with AND/OR operators (used in vacancy search bar)
- `select2` — Select2 wrapper for static and AJAX-loaded selects; modal-aware dropdown parent

## Reference Docs

- `.ai/docs/rspec.md` — shared operation context, Elasticsearch test setup, job specs, factory patterns. **Read before modifying any spec file.**
- `.ai/docs/cucumber.md` — all available Given/When/Then steps, page navigation syntax, Turbo waiting, ES/job support. **Read before writing feature tests.**
- `.ai/docs/operations.md` — Operation::Base API, authorization methods, error handling, sub-operations, skeleton templates.
- `.ai/docs/form_objects.md` — FormObject DSL (`property`, `has_many`, `has_one`), sync lifecycle, attachment validation, skeletons.
- `.ai/docs/i18n.md` — key naming conventions, namespace structure, pluralization, workflow for adding new keys.
- `.ai/docs/simple_form.md` — `simple_form_for` usage, wrapper types, select/file/hidden inputs, Turbo modal forms, Stimulus integration, skeletons.
- `.ai/docs/turbo_form_controller.md` — `turbo-form` Stimulus controller: live re-render on field change, dependent selects, submit-button management, custom fetch URL.
- `.ai/docs/view_component.md` — component decision tree (check helper first, shared vs resource-scoped), base class features, skeleton.

<!-- rtk-instructions v2 -->
# RTK (Rust Token Killer) - Token-Optimized Commands

## Golden Rule

**Always prefix commands with `rtk`**. If RTK has a dedicated filter, it uses it. If not, it passes through unchanged. This means RTK is always safe to use.

**Important**: Even in command chains with `&&`, use `rtk`:
```bash
# ❌ Wrong
git add . && git commit -m "msg" && git push

# ✅ Correct
rtk git add . && rtk git commit -m "msg" && rtk git push
```

## RTK Commands by Workflow

### Build & Compile (80-90% savings)
```bash
rtk cargo build         # Cargo build output
rtk cargo check         # Cargo check output
rtk cargo clippy        # Clippy warnings grouped by file (80%)
rtk tsc                 # TypeScript errors grouped by file/code (83%)
rtk lint                # ESLint/Biome violations grouped (84%)
rtk prettier --check    # Files needing format only (70%)
rtk next build          # Next.js build with route metrics (87%)
```

### Test (90-99% savings)
```bash
rtk cargo test          # Cargo test failures only (90%)
rtk vitest run          # Vitest failures only (99.5%)
rtk playwright test     # Playwright failures only (94%)
rtk test <cmd>          # Generic test wrapper - failures only
```

### Git (59-80% savings)
```bash
rtk git status          # Compact status
rtk git log             # Compact log (works with all git flags)
rtk git diff            # Compact diff (80%)
rtk git show            # Compact show (80%)
rtk git add             # Ultra-compact confirmations (59%)
rtk git commit          # Ultra-compact confirmations (59%)
rtk git push            # Ultra-compact confirmations
rtk git pull            # Ultra-compact confirmations
rtk git branch          # Compact branch list
rtk git fetch           # Compact fetch
rtk git stash           # Compact stash
rtk git worktree        # Compact worktree
```

Note: Git passthrough works for ALL subcommands, even those not explicitly listed.

### GitHub (26-87% savings)
```bash
rtk gh pr view <num>    # Compact PR view (87%)
rtk gh pr checks        # Compact PR checks (79%)
rtk gh run list         # Compact workflow runs (82%)
rtk gh issue list       # Compact issue list (80%)
rtk gh api              # Compact API responses (26%)
```

### JavaScript/TypeScript Tooling (70-90% savings)
```bash
rtk pnpm list           # Compact dependency tree (70%)
rtk pnpm outdated       # Compact outdated packages (80%)
rtk pnpm install        # Compact install output (90%)
rtk npm run <script>    # Compact npm script output
rtk npx <cmd>           # Compact npx command output
rtk prisma              # Prisma without ASCII art (88%)
```

### Files & Search (60-75% savings)
```bash
rtk ls <path>           # Tree format, compact (65%)
rtk read <file>         # Code reading with filtering (60%)
rtk grep <pattern>      # Search grouped by file (75%)
rtk find <pattern>      # Find grouped by directory (70%)
```

### Analysis & Debug (70-90% savings)
```bash
rtk err <cmd>           # Filter errors only from any command
rtk log <file>          # Deduplicated logs with counts
rtk json <file>         # JSON structure without values
rtk deps                # Dependency overview
rtk env                 # Environment variables compact
rtk summary <cmd>       # Smart summary of command output
rtk diff                # Ultra-compact diffs
```

### Infrastructure (85% savings)
```bash
rtk docker ps           # Compact container list
rtk docker images       # Compact image list
rtk docker logs <c>     # Deduplicated logs
rtk kubectl get         # Compact resource list
rtk kubectl logs        # Deduplicated pod logs
```

### Network (65-70% savings)
```bash
rtk curl <url>          # Compact HTTP responses (70%)
rtk wget <url>          # Compact download output (65%)
```

### Meta Commands
```bash
rtk gain                # View token savings statistics
rtk gain --history      # View command history with savings
rtk discover            # Analyze Claude Code sessions for missed RTK usage
rtk proxy <cmd>         # Run command without filtering (for debugging)
rtk init                # Add RTK instructions to CLAUDE.md
rtk init --global       # Add RTK to ~/.claude/CLAUDE.md
```

## Token Savings Overview

| Category | Commands | Typical Savings |
|----------|----------|-----------------|
| Tests | vitest, playwright, cargo test | 90-99% |
| Build | next, tsc, lint, prettier | 70-87% |
| Git | status, log, diff, add, commit | 59-80% |
| GitHub | gh pr, gh run, gh issue | 26-87% |
| Package Managers | pnpm, npm, npx | 70-90% |
| Files | ls, read, grep, find | 60-75% |
| Infrastructure | docker, kubectl | 85% |
| Network | curl, wget | 65-70% |

Overall average: **60-90% token reduction** on common development operations.
<!-- /rtk-instructions -->