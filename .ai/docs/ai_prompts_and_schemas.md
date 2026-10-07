# AI Prompts & Response Schemas

This document covers `Prompt` and `ResponseSchema` objects — the two halves of every AI request — and `AiHandler`, which wires them together.

## Overview

```
Operation
  └─ ApplyMate::Ai::AiHandler.call(
       prompt_instance:,        # Prompt::Base subclass instance
       response_schema_class:,  # ResponseSchema::Base subclass (class, not instance)
       ai_integration:          # AiIntegration AR model (provider, api_key, host, model)
     )
       │
       ├─ client_class = AiIntegration::PROVIDER_CLIENTS.fetch(provider)
       ├─ prompt_instance.call + response_schema_class.format_instructions → full_prompt
       ├─ ApplyMate::Ai::Request.for(kind: response_schema_class.kind, text: full_prompt,
       │                             json_schema: (schema.json_schema if schema.native_schema?))
       ├─ client.complete(request)  → ApplyMate::Ai::Response(text, usage)
       ├─ log "[ApplyMate::Ai::AiHandler] <client> kind=… input_tokens=… output_tokens=…"
       └─ response_schema_class.extract(response.text) → parsed result
```

## File Locations

```
app/concepts/
  apply_mate/ai/
    prompt/base.rb                          # ApplyMate::Ai::Prompt::Base
    response_schema/base.rb                # ApplyMate::Ai::ResponseSchema::Base
    response_schema/json.rb                # ApplyMate::Ai::ResponseSchema::Json (ONE json extract+validate)
    ai_handler.rb                          # ApplyMate::Ai::AiHandler
    request.rb                             # ApplyMate::Ai::Request  (Data.define value type)
    response.rb                            # ApplyMate::Ai::Response (Data.define value type)
    usage.rb                               # ApplyMate::Ai::Usage    (Data.define value type)
    client/base.rb                         # ApplyMate::Ai::Client::Base (capabilities, complete)
    client/gemini.rb                       # ApplyMate::Ai::Client::Gemini         (Gemini API)
    client/ollama.rb                       # ApplyMate::Ai::Client::Ollama         (self-hosted)
    client/gemini_scraping.rb              # ApplyMate::Ai::Client::GeminiScraping (web UI via Ferrum)
  apply/ai/
    prompt/
      fill_form.rb                         # Apply::Ai::Prompt::FillForm        (shared)
      generate_cv.rb                       # Apply::Ai::Prompt::GenerateCv      (shared)
      check_form_page.rb                   # Apply::Ai::Prompt::CheckFormPage   (shared)
      browser/check_submit_result.rb       # Apply::Ai::Prompt::Browser::CheckSubmitResult
    response_schema/
      fill_form.rb                         # Apply::Ai::ResponseSchema::FillForm
      generate_cv.rb                       # Apply::Ai::ResponseSchema::GenerateCv
      check_form_page.rb                   # Apply::Ai::ResponseSchema::CheckFormPage
      browser/check_submit_result.rb       # Apply::Ai::ResponseSchema::Browser::CheckSubmitResult
  vacancy_question/ai/
    prompt/answer_question.rb              # VacancyQuestion::Ai::Prompt::AnswerQuestion
    response_schema/answer_question.rb     # VacancyQuestion::Ai::ResponseSchema::AnswerQuestion
```

Namespace convention: prompts and schemas shared across job boards live directly at `Apply::Ai::Prompt::<Action>` — **no source namespace**. Only add a source sub-namespace (e.g. `Apply::Ai::Prompt::Djinni::`) when the logic is genuinely source-specific and will never be reused.

---

## Prompt Objects

### Base class — `ApplyMate::Ai::Prompt::Base`

```ruby
class ApplyMate::Ai::Prompt::Base
  def self.call(...)   # delegates to new(...).call
  def initialize(*args, **kwargs)
  def call             # → String; subclasses must implement
end
```

`AiHandler` always calls `.new(...)` then `#call`, but `Base.call(...)` is available as a convenience shortcut.

### Implementing a Prompt

1. Subclass `ApplyMate::Ai::Prompt::Base`.
2. Define a `PROMPT_TEMPLATE` constant with `PLACEHOLDER_*` tokens where runtime data will be injected.
3. Accept whatever the operation passes in `initialize`.
4. Implement `call` to resolve data and substitute all placeholders. Return `nil` (or the operation should guard) if required data is missing.

```ruby
class Apply::Ai::Prompt::Djinni::FillForm < ApplyMate::Ai::Prompt::Base
  PROMPT_TEMPLATE = <<~PROMPT
    ...
    PLACEHOLDER_VACANCY_CONTEXT
    ...
    PLACEHOLDER_USER_EXPERIENCE
    ...
    PLACEHOLDER_FORM_FIELDS
  PROMPT

  def initialize(apply)
    @apply = apply
  end

  def call
    # Build runtime strings
    vacancy_context = ...
    user_experience = ...
    fields_info     = ...

    return if fields_info.blank?  # guard before substitution

    PROMPT_TEMPLATE
      .sub('PLACEHOLDER_VACANCY_CONTEXT', vacancy_context)
      .sub('PLACEHOLDER_USER_EXPERIENCE', user_experience)
      .sub('PLACEHOLDER_FORM_FIELDS',     fields_info)
  end
end
```

### Field-Level Instructions Inside Prompts

For structured form prompts, per-field instructions are built inline within `call` using a `case input['name']` block. Append instructions as additional text on the same line:

```ruby
case input['name']
when 'message'
  line += '. INSTRUCTION: ...'
when 'save_msg_template'
  line += ". INSTRUCTION: Always return 'false'."
end
```

Radio inputs also enumerate their options so the AI returns the `value`, not the human-readable label:

```ruby
if input['type'] == 'radio' && input['options'].present?
  options_str = input['options'].map { |o| "#{o['label']}=#{o['value']}" }.join(', ')
  line += ". Options: #{options_str}. INSTRUCTION: Return the value (not label) of your chosen option."
end
```

---

## Response Schema Objects

A `ResponseSchema` class has these class methods:

| Method                  | Purpose                                                                                                                                                                                                           |
| ----------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `kind`                  | One of `ApplyMate::Ai::Request::KINDS` (`:navigate`, `:answers`, `:verify`, `:cv`). **Required** — `AiHandler` sizes the request (`max_output_tokens`, `timeout`) from it; the base raises `NotImplementedError`. |
| `format_instructions`   | Returns a string appended to the full prompt. Tells the AI exactly how to format the response (JSON, HTML code block, etc.).                                                                                      |
| `extract(raw_response)` | Parses the AI's raw string output into the final value consumed by the operation.                                                                                                                                 |
| `json_schema`           | JSON-Schema Hash for JSON answers (`Json` subclasses); `nil` on `Base`.                                                                                                                                           |
| `native_schema?`        | Whether `AiHandler` sends `json_schema` to the provider (Gemini `responseSchema`, Ollama `format`). `false` on `Base`.                                                                                            |

### Base class — `ApplyMate::Ai::ResponseSchema::Base`

```ruby
class ApplyMate::Ai::ResponseSchema::Base
  def self.kind                  # → Symbol in Request::KINDS; subclasses must implement
  def self.format_instructions   # → String; subclasses must implement
  def self.extract(raw_response) # → parsed value; subclasses must implement
  def self.json_schema           # → nil  (overridden by Json subclasses)
  def self.native_schema?        # → false (overridden by Json)
end
```

`json_schema` / `native_schema?` live on `Base` so `AiHandler` can ask any schema class without `respond_to?`.

### Implementing a ResponseSchema

#### JSON answers — subclass `ApplyMate::Ai::ResponseSchema::Json`

Every JSON answer goes through **one** extract+validate implementation. Never write a fence regex or `JSON.parse` in a schema class — `json.rb` is the only place that calls `JSON.parse` on AI output.

```ruby
class ApplyMate::Ai::ResponseSchema::Json < ApplyMate::Ai::ResponseSchema::Base
  class InvalidResponse < StandardError; end

  def self.json_schema           # abstract → Hash (raises NotImplementedError)
  def self.native_schema?        # → json_schema[:properties].present?
  def self.extract(raw_response) # → validate!(parse(raw_response)).with_indifferent_access
end
```

**`json_schema`** — top-level `type: 'object'`, symbol keys, JSON-Schema subset: `type`, `properties`, `required`, `items`, `enum`, `minLength`, `additionalProperties`. Nullable fields are `type: %w[string null]` (Gemini maps that to `nullable: true`; `gemini_schema` drops keys it does not know, e.g. `additionalProperties`, `minLength`).

**`parse`** (private):

1. Blank → `InvalidResponse, 'blank AI response'`.
2. Prefers the inner text of a ` ```json ` (or bare ` ``` `) fence.
3. Narrows to the outermost JSON object: from the first `{` to the last `}` (so prose around the JSON is ignored). Objects only — every schema is top-level `type: 'object'`, and a `[` in the prose (e.g. a CSS selector `a[href*=apply]`) must not be taken as the start of the JSON.
4. `JSON::ParserError` → `InvalidResponse, "AI response is not valid JSON: <parser message>"`.

Native-schema answers (raw JSON) and text-mode answers (fenced or prose-wrapped) both parse, so WebMock stubs may keep feeding fenced JSON even when a schema was sent natively.

**`validate!`** (private) — `JSON::Validator.fully_validate(json_schema.deep_stringify_keys, data, version: :draft6, parse_data: false)` from the `json-schema` gem (it has no draft-7 validator; draft-6 covers the subset above identically). Any errors → `InvalidResponse, errors.join('; ')`. `parse_data: false` is load-bearing: with the gem default a String datum is re-parsed and, failing that, opened as a URI or file path — AI output must never reach `URI.open` / `File.read`.

No rescue-and-log inside schemas: `InvalidResponse` propagates to the operation, and `Apply::Operation::Base` records it in `apply.error` with the step's `failed_*` status.

**`native_schema?`** — Gemini's `responseSchema` needs fixed keys, so a schema that only declares `additionalProperties` (dynamic keys) is used for validation but never sent natively.

| Schema                                                  | `kind`      | Native?            | `json_schema` / notes                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| ------------------------------------------------------- | ----------- | ------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Apply::Ai::ResponseSchema::CheckFormPage`              | `:navigate` | yes                | required `has_form` (boolean), `trigger_selector`/`form_url`/`form_selector` (`string \| null`); `additionalProperties: false`. A blank or invalid answer raises `InvalidResponse` → `FetchExternalForm` fails with `failed_fetching_form` (there is no `has_form: false` default any more).                                                                                                                                                                                                                    |
| `Apply::Ai::ResponseSchema::Browser::CheckSubmitResult` | `:verify`   | yes                | required `success` (boolean), `reason` (string). Strict like every `Json` schema: an unusable answer raises `InvalidResponse`. `Apply::Operation::SendApply::Browser#verify_submit` turns `success: false` into `Halt(:validation_rejected)` (not definitive) and lets `InvalidResponse` / a client `EmptyResponse` propagate (the Runner maps them to `invalid_ai_output`, `Run::ERROR_CODES`): the claim is kept, so all of them end in `submit_unverified` (an AI verdict alone never releases a claim, design §11.4). |
| `VacancyQuestion::Ai::ResponseSchema::AnswerQuestion`   | `:answers`  | yes                | required `answer` (`string`, `minLength: 1`); `extract` returns `super[:answer]` (a String) and raises `InvalidResponse, 'AI AnswerQuestion response has no answer'` when it is whitespace-only (no `pattern` in the schema: llama.cpp's grammar conversion behind Ollama `format` rejects unanchored patterns).                                                                                                                                                                                                |
| `Apply::Ai::ResponseSchema::FillForm`                   | `:answers`  | **no** (text-mode) | `{ type: 'object', additionalProperties: { type: %w[string number boolean null] } }` — keys are the form's own input names. Scalars are accepted because `Apply::Operation::Ai::FillForm` stringifies every value; nested objects/arrays are rejected. `{}` passes validation and the operation's own blank guard raises.                                                                                                                                                                                       |

`AiHandler` appends `format_instructions` for every client, native or not: the instruction text carries the field semantics the schema cannot express.

#### Binary schema (e.g. GenerateCv → PDF)

`format_instructions` asks the AI to return raw HTML inside a fenced code block. `extract` strips the fence, validates the HTML, injects CSS, and converts to PDF via Grover:

````ruby
class Apply::Ai::ResponseSchema::Djinni::GenerateCv < ApplyMate::Ai::ResponseSchema::Base
  def self.kind
    :cv
  end

  def self.format_instructions
    # Instructs AI: output the full HTML document inside ```html ... ```
  end

  def self.extract(raw_response)
    # 1. Strip ```html ... ``` fence
    # 2. Validate it looks like an HTML document
    # 3. Wrap in styled <html> shell
    # 4. Grover.new(styled_html).to_pdf(..., timeout: 60_000)  → binary PDF string (60 s render cap)
  end
end
````

`GenerateCv` stays a `Base` subclass (HTML → PDF, not JSON): `json_schema` is `nil`, so nothing is sent natively. The return type of `extract` determines what the operation receives — a `HashWithIndifferentAccess` (Json subclasses), a `String` (AnswerQuestion) or binary PDF bytes (GenerateCv).

---

## AiHandler

`ApplyMate::Ai::AiHandler.call` is the single integration point between prompts, schemas, and the AI client:

```ruby
ApplyMate::Ai::AiHandler.call(
  prompt_instance:       Apply::Ai::Prompt::FillForm.new(apply),
  response_schema_class: Apply::Ai::ResponseSchema::FillForm,
  ai_integration:        apply.ai_integration
)
```

Internally:

1. Looks up the client class from `ai_integration.provider` in `AiIntegration::PROVIDER_CLIENTS`.
2. Builds the client once (`api_key:`, `host:`, `model:`).
3. Concatenates `prompt_instance.call` + `response_schema_class.format_instructions` into one user message.
4. `client.complete(ApplyMate::Ai::Request.for(kind: response_schema_class.kind, text: full_prompt, json_schema:))` where `json_schema` is `response_schema_class.json_schema` when `native_schema?`, else `nil`.
5. Logs one info line tagged `[ApplyMate::Ai::AiHandler]` (via `ApplyMate::Logging`) with client class, kind, input/output tokens.
6. Returns `response_schema_class.extract(response.text)`.

There is no capability gate in `AiHandler`: no caller needs one yet. When a phase introduces a call that cannot work without a capability, the caller checks `client_class.supports?(:json_schema)` (one capability API: `Client::Base.supports?`).

Always call `AiHandler` from an operation (or a job that is the operation's entry point), not directly from a controller.

---

## Request / Response / Usage

Three immutable `Data.define` value types in the `ApplyMate::Ai` namespace (same precedent as `ApplyMate::Client::Response`):

| Type                      | Fields                                                                                                                                                                                                                                                                                                                                                                                                                         |
| ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `ApplyMate::Ai::Request`  | `system` (String/nil), `messages` (Array of `{ role: 'user' \| 'model', content: String }`), `images` (Array of `{ mime_type:, data: <base64> }` — always empty in phase 0), `json_schema` (Hash/nil), `timeout` (seconds), `max_output_tokens` (visible answer cap), `thinking_budget` (reasoning tokens on top); `#output_token_limit` = `max_output_tokens + thinking_budget` is what clients send as the provider-side cap |
| `ApplyMate::Ai::Response` | `text` (String — what `extract` parses), `usage` (`Usage`)                                                                                                                                                                                                                                                                                                                                                                     |
| `ApplyMate::Ai::Usage`    | `input_tokens`, `output_tokens` (either may be nil); `Usage::UNKNOWN` when the provider reports nothing                                                                                                                                                                                                                                                                                                                        |

`Request.for(kind:, text:, json_schema: nil, system: nil, images: [])` builds `messages: [{ role: 'user', content: text }]` and sizes the request from three tables keyed by kind (an unknown kind raises `KeyError` on purpose):

| Kind        | `MAX_OUTPUT_TOKENS` | `THINKING_BUDGETS` | `TIMEOUTS` (s) | Schemas                                                                                      |
| ----------- | ------------------: | -----------------: | -------------: | -------------------------------------------------------------------------------------------- |
| `:navigate` |               1 024 |              1 024 |             60 | `Apply::Ai::ResponseSchema::CheckFormPage`                                                   |
| `:answers`  |               4 096 |              2 048 |             90 | `Apply::Ai::ResponseSchema::FillForm`, `VacancyQuestion::Ai::ResponseSchema::AnswerQuestion` |
| `:verify`   |                 512 |                512 |             30 | `Apply::Ai::ResponseSchema::Browser::CheckSubmitResult`                                      |
| `:cv`       |               8 192 |              2 048 |            180 | `Apply::Ai::ResponseSchema::GenerateCv`                                                      |

**Thinking budget:** Gemini 2.5+ (and Ollama thinking models such as qwen3) spend reasoning tokens from the same output cap as the answer. Without a bound, dynamic thinking can eat the whole cap and the candidate comes back with `finishReason: "MAX_TOKENS"` and no text. So clients send `output_token_limit` (answer + thinking) as the cap, and `Client::Gemini` also sends `thinking_config.thinking_budget` for models matching `THINKING_MODEL`. Every budget is ≥ 512, the smallest non-zero `thinking_budget` all Gemini 2.5 models accept (flash-lite's floor). If a provider still returns no text (safety block, cut-off), the client raises `ApplyMate::Ai::Client::Base::EmptyResponse` naming `finishReason`, `blockReason` and `thoughtsTokenCount` (Gemini) or `done_reason` (Ollama) instead of returning nil.

## Clients and capabilities

`ApplyMate::Ai::Client::Base` API:

| Method                                            | Notes                                                                                                                                                                                                                                     |
| ------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `self.capabilities`                               | Frozen Array of `:json_schema`, `:vision`, `:browser_backed`. Base: `[]`.                                                                                                                                                                 |
| `self.supports?(capability)`                      | `capabilities.include?(capability)`                                                                                                                                                                                                       |
| `complete(request)`                               | `Request` → `Response`. Abstract.                                                                                                                                                                                                         |
| `assert_request!(request)` (protected)            | Raises `CapabilityMissing` when `request.images.any?` on a client without `:vision`. A `json_schema` on a client without `:json_schema` is **not** an error — it is just not sent natively; `format_instructions` still steers the model. |
| `self.validate_api_key!(api_key:)`, `list_models` | Unchanged; used by the AiIntegration forms.                                                                                                                                                                                               |

| Client           | `capabilities`       | Wire mapping                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| ---------------- | -------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Gemini`         | `json_schema vision` | `::Gemini` built per `complete` with `options.connection.request.timeout = request.timeout` (constructor-built client is for `list_models` only). Body: `system_instruction`, `contents` (role `user`/`model`, images as `inline_data` parts on the last user turn), `generation_config.max_output_tokens = request.output_token_limit`, `generation_config.thinking_config = { thinking_budget: request.thinking_budget }` only when the model matches `THINKING_MODEL` (Gemini 2.5+/3.x `pro`/`flash`/`flash-lite`, incl. dated previews — 2.0/1.5 and image/tts variants reject the field with a 400), plus `response_mime_type: 'application/json'` + `response_schema` **only** when `json_schema` is given. `gemini_schema` converts the JSON-Schema subset once, recursively: `type` upcased, `['string', 'null']` → `type: 'STRING', nullable: true`, keeps `properties/required/items/enum/description`, drops everything else (e.g. `additionalProperties`); a union of several non-null types raises `ArgumentError`. 429/502/503 retried twice (sleep 2 s, 4 s). Usage: `promptTokenCount` → input; `candidatesTokenCount + thoughtsTokenCount` → output (thinking is billed as output). |
| `Ollama`         | `json_schema`        | `::Ollama` built per `complete` with `server_sent_events: false` and the request timeout. `POST /api/chat` with `stream: false`, optional leading `system` message, roles `user`/`assistant`, `format: <schema hash>` when given, `options: { num_ctx: NUM_CTX, num_predict: request.output_token_limit }`. ollama-ai 1.3.0 returns the non-SSE body as a one-element Array (JSON Lines) — the client takes `.sole`. Usage: `prompt_eval_count` / `eval_count`. Vision is model-dependent and not declared, so images raise `CapabilityMissing`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| `GeminiScraping` | `browser_backed`     | Flattens `[system, *messages.content].compact.join("\n\n")` into one prompt typed into gemini.google.com via Ferrum (private `scrape_answer`), returns `Usage::UNKNOWN`. Ignores `request.timeout`; the answer has its own `RESPONSE_TIMEOUT = 180` s polling deadline. Chrome is launched inside `scrape_answer` (and quit in its `ensure`), never in the constructor.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |

`Ollama::NUM_CTX = 16_384`: prompts carry ~20k chars of minimised HTML plus the CV and vacancy text; Ollama's server default context silently truncates the prompt head instead of failing.

`browser_backed` means the client occupies a browser on the host; callers that already hold a browser (later phases: the leased apply scope) pass/check it explicitly rather than discovering it at runtime.

---

## DB-backed Prompt Templates

Prompt templates are stored in the `Prompt` model (`app/models/prompt.rb`) so users can customise them without a deploy. Each user has one prompt per type (`fill_form`, `generate_cv`).

**Pattern:** keep the `PROMPT_TEMPLATE` constant as a fallback, add a private `template` method that looks up the user's DB record:

```ruby
def call
  template
    .sub('PLACEHOLDER_FOO', foo_value)
    .sub('PLACEHOLDER_BAR', bar_value)
end

private

def template
  @apply.user.prompts.find_by(prompt_type: :fill_form)&.content || PROMPT_TEMPLATE
end
```

Use `@apply.user` (direct FK on `applies.user_id`) — not `@apply.user_profile.user`.

**Validation:** `Prompt::REQUIRED_PLACEHOLDERS` maps each type to the placeholder strings that must appear in the content. The model validates this on save.

**When adding a new prompt type:**

1. Add the type to `Prompt.enum :prompt_type` and `REQUIRED_PLACEHOLDERS` in `app/models/prompt.rb`.
2. Add a `template` private method to the prompt class following the pattern above.

## Adding a New Prompt + Schema Pair

1. Decide namespace: shared across sources → `Apply::Ai::Prompt::<Action>`; source-specific → `Apply::Ai::Prompt::<Source>::<Action>`.
2. Create the prompt file — subclass `ApplyMate::Ai::Prompt::Base`.
3. Create the response schema file — for a JSON answer subclass `ApplyMate::Ai::ResponseSchema::Json` and implement `kind`, `json_schema` and `format_instructions` (override `extract` only to post-process `super`); for a non-JSON answer subclass `ApplyMate::Ai::ResponseSchema::Base` and implement `kind`, `format_instructions` and `extract`. If the new call needs a different output cap/timeout, add a kind to `ApplyMate::Ai::Request::KINDS`, `MAX_OUTPUT_TOKENS`, `THINKING_BUDGETS` and `TIMEOUTS` together.
4. Call `ApplyMate::Ai::AiHandler.call(...)` from the operation, passing the new prompt and schema.
5. The operation receives whatever `extract` returns — handle accordingly.

## Skeleton

```ruby
# app/concepts/<resource>/ai/prompt/<action>.rb  (shared) or prompt/<source>/<action>.rb (source-specific)
class <Resource>::Ai::Prompt::<Action> < ApplyMate::Ai::Prompt::Base
  PROMPT_TEMPLATE = <<~PROMPT
    ...
    PLACEHOLDER_FOO
    PLACEHOLDER_BAR
  PROMPT

  def initialize(model)
    @model = model
  end

  def call
    PROMPT_TEMPLATE
      .sub('PLACEHOLDER_FOO', ...)
      .sub('PLACEHOLDER_BAR', ...)
  end
end

# app/concepts/<resource>/ai/response_schema/<action>.rb  (shared) or response_schema/<source>/<action>.rb
# JSON answer: parsing and validation come from Json — no regex, no JSON.parse here.
class <Resource>::Ai::ResponseSchema::<Action> < ApplyMate::Ai::ResponseSchema::Json
  def self.kind
    :answers # one of ApplyMate::Ai::Request::KINDS
  end

  def self.json_schema
    {
      type:       'object',
      required:   %w[answer note],
      properties: {
        answer: { type: 'string', minLength: 1 },
        note:   { type: %w[string null] }
      }
    }
  end

  def self.format_instructions
    # Field semantics in prose — still appended when the schema is sent natively
  end

  # Optional: post-process the validated hash
  def self.extract(raw_response)
    super[:answer]
  end
end
```
