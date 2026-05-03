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
       ├─ prompt_instance.call        → full_prompt string
       ├─ response_schema_class.format_instructions → appended to prompt
       ├─ client.ask(full_prompt)     → raw_response string
       └─ response_schema_class.extract(raw_response) → parsed result
```

## File Locations

```
app/concepts/
  apply_mate/ai/
    prompt/base.rb             # ApplyMate::Ai::Prompt::Base
    response_schema/base.rb   # ApplyMate::Ai::ResponseSchema::Base
    ai_handler.rb             # ApplyMate::Ai::AiHandler
  apply/ai/
    prompt/djinni/
      fill_form.rb            # Apply::Ai::Prompt::Djinni::FillForm
      generate_cv.rb          # Apply::Ai::Prompt::Djinni::GenerateCv
    response_schema/djinni/
      fill_form.rb            # Apply::Ai::ResponseSchema::Djinni::FillForm
      generate_cv.rb          # Apply::Ai::ResponseSchema::Djinni::GenerateCv
```

Namespace convention: `<Resource>::Ai::Prompt::<Source>::<Action>` and `<Resource>::Ai::ResponseSchema::<Source>::<Action>`, where `<Source>` is the job board (e.g. `Djinni`).

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

A `ResponseSchema` class has two class-method responsibilities:

| Method | Purpose |
|--------|---------|
| `format_instructions` | Returns a string appended to the full prompt. Tells the AI exactly how to format the response (JSON, HTML code block, etc.). |
| `extract(raw_response)` | Parses the AI's raw string output into the final value consumed by the operation. |

### Base class — `ApplyMate::Ai::ResponseSchema::Base`

```ruby
class ApplyMate::Ai::ResponseSchema::Base
  def self.format_instructions   # → String; subclasses must implement
  def self.extract(raw_response) # → parsed value; subclasses must implement
end
```

### Implementing a ResponseSchema

#### JSON schema (e.g. FillForm)

`format_instructions` asks the AI to return a JSON object. `extract` strips any Markdown fences and calls `JSON.parse`:

```ruby
class Apply::Ai::ResponseSchema::Djinni::FillForm < ApplyMate::Ai::ResponseSchema::Base
  def self.format_instructions
    <<~INSTRUCTIONS
      Return the result exclusively as a JSON object where the key is the input name
      and the value is the text to fill in. No extra explanations or Markdown (except
      the code block itself). Do not include "file" type fields.
    INSTRUCTIONS
  end

  def self.extract(raw_response)
    return {} if raw_response.blank?

    match   = raw_response.match(/```json\s+(.*?)\s+```/m)
    json_str = match ? match[1] : raw_response
    json_str = json_str.match(/(\{.*\}|\[.*\])/m)&.then { |m| m[0] } || json_str

    JSON.parse(json_str).with_indifferent_access
  rescue StandardError => e
    Rails.logger.error("Failed to parse AI response: #{e.message}")
    raise "Failed to parse AI response: #{e.message}"
  end
end
```

#### Binary schema (e.g. GenerateCv → PDF)

`format_instructions` asks the AI to return raw HTML inside a fenced code block. `extract` strips the fence, validates the HTML, injects CSS, and converts to PDF via Grover:

```ruby
class Apply::Ai::ResponseSchema::Djinni::GenerateCv < ApplyMate::Ai::ResponseSchema::Base
  def self.format_instructions
    # Instructs AI: output the full HTML document inside ```html ... ```
  end

  def self.extract(raw_response)
    # 1. Strip ```html ... ``` fence
    # 2. Validate it looks like an HTML document
    # 3. Wrap in styled <html> shell
    # 4. Grover.new(styled_html).to_pdf(...)  → binary PDF string
  end
end
```

The return type of `extract` determines what the operation receives — a `Hash` (FillForm) or a binary `String` (GenerateCv PDF bytes).

---

## AiHandler

`ApplyMate::Ai::AiHandler.call` is the single integration point between prompts, schemas, and the AI client:

```ruby
ApplyMate::Ai::AiHandler.call(
  prompt_instance:      Apply::Ai::Prompt::Djinni::FillForm.new(apply),
  response_schema_class: Apply::Ai::ResponseSchema::Djinni::FillForm,
  ai_integration:       apply.ai_integration
)
```

Internally:
1. Builds the client from `ai_integration.provider` (looked up in `AiIntegration::PROVIDER_CLIENTS`).
2. Concatenates `prompt_instance.call` + `response_schema_class.format_instructions`.
3. Sends the combined string via `client.ask(full_prompt)`.
4. Returns `response_schema_class.extract(raw_response)`.

Always call `AiHandler` from an operation, not directly from a controller or job.

---

## Adding a New Prompt + Schema Pair

1. Create `app/concepts/<resource>/ai/prompt/<source>/<action>.rb` — subclass `ApplyMate::Ai::Prompt::Base`.
2. Create `app/concepts/<resource>/ai/response_schema/<source>/<action>.rb` — subclass `ApplyMate::Ai::ResponseSchema::Base`, implement both class methods.
3. Call `ApplyMate::Ai::AiHandler.call(...)` from the operation, passing the new prompt and schema.
4. The operation receives whatever `extract` returns — handle accordingly.

## Skeleton

```ruby
# app/concepts/<resource>/ai/prompt/<source>/<action>.rb
class <Resource>::Ai::Prompt::<Source>::<Action> < ApplyMate::Ai::Prompt::Base
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

# app/concepts/<resource>/ai/response_schema/<source>/<action>.rb
class <Resource>::Ai::ResponseSchema::<Source>::<Action> < ApplyMate::Ai::ResponseSchema::Base
  def self.format_instructions
    # Tell the AI how to format its output
  end

  def self.extract(raw_response)
    # Parse raw_response into the value the operation needs
  end
end
```
