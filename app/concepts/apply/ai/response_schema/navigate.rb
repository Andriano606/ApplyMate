# frozen_string_literal: true

# One Navigator decision (design §6.2) for Apply::Ai::Prompt::Navigate, sent natively (Gemini responseSchema, Ollama
# format). The action vocabulary is CLOSED and has no `fill`: the Navigator only moves through pages, it never types.
#
#   status        continue | form_reached | give_up
#   reason        short English diagnostic (traced, shown to the owner only under "diagnostics")
#   actions       <= MAX_ACTIONS: { type, ref, key, index, max_ms } (unused members null)
#   form          form_reached only: { frame, scope_ref, field_refs, submit_ref, advance_ref }, else null
#   give_up_code  give_up only: one of GIVE_UP_CODES, else null
#
# Schema-valid is not yet usable: Engine::Navigate rejects a give_up without a code, a form_reached without a form and
# a continue without actions as invalid output, and Engine::ExecuteAction validates every action against the page.
class Apply::Ai::ResponseSchema::Navigate < ApplyMate::Ai::ResponseSchema::Json
  STATUSES = %w[continue form_reached give_up].freeze
  ACTION_TYPES = %w[click press scroll navigate switch_tab wait].freeze
  KEYS = Apply::Recipe::Op::Press::KEYS
  GIVE_UP_CODES = %w[login_required no_application_path closed_posting bot_wall not_a_form captcha_challenge
                     external_messenger].freeze
  MAX_ACTIONS = 3

  def self.kind
    :navigate
  end

  def self.json_schema
    {
      type: 'object',
      required: %w[status reason actions form give_up_code],
      properties: {
        status: { type: 'string', enum: STATUSES },
        reason: { type: 'string' },
        actions: { type: 'array', maxItems: MAX_ACTIONS, items: action_schema },
        form: form_schema,
        give_up_code: { type: %w[string null], enum: [ *GIVE_UP_CODES, nil ] }
      },
      additionalProperties: false
    }
  end

  # One action item; `types` narrows the vocabulary (ResponseSchema::RecoverField: click / press only).
  def self.action_schema(types: ACTION_TYPES)
    {
      type: 'object',
      required: %w[type ref key index max_ms],
      properties: {
        type: { type: 'string', enum: types },
        ref: { type: %w[string null] },
        key: { type: %w[string null], enum: [ *KEYS, nil ] },
        index: { type: %w[integer null] },
        max_ms: { type: %w[integer null] }
      },
      additionalProperties: false
    }
  end

  def self.form_schema
    {
      type: %w[object null],
      required: %w[frame scope_ref field_refs submit_ref advance_ref],
      properties: {
        frame: { type: 'string' },
        scope_ref: { type: 'string' },
        field_refs: { type: 'array', items: { type: 'string' } },
        submit_ref: { type: %w[string null] },
        advance_ref: { type: %w[string null] }
      },
      additionalProperties: false
    }
  end
  private_class_method :form_schema

  def self.format_instructions
    <<~INSTRUCTIONS
      Response format:
      Return one JSON object with exactly these keys:
      {"status": "continue"|"form_reached"|"give_up", "reason": "<one short English sentence>",
       "actions": [{"type": "click"|"press"|"scroll"|"navigate"|"switch_tab"|"wait", "ref": "<fN:eM>"|null,
                    "key": "ArrowDown"|"Enter"|"Escape"|"Tab"|null, "index": <tab index>|null, "max_ms": <ms>|null}],
       "form": {"frame": "<fN>", "scope_ref": "<fN:eM>", "field_refs": ["<fN:eM>", ...], "submit_ref": "<fN:eM>"|null,
                "advance_ref": "<fN:eM>"|null} | null,
       "give_up_code": #{GIVE_UP_CODES.map { |code| %("#{code}") }.join('|')}|null}
      At most #{MAX_ACTIONS} actions; an action that changes the page must be the last one. Use only refs listed on the page.
      "continue" needs at least one action; "form_reached" needs "form" and no actions; "give_up" needs "give_up_code".
      Wrap the JSON in a ```json code block. No extra text outside the code block.
    INSTRUCTIONS
  end
end
