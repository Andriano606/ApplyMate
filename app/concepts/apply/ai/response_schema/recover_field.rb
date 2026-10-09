# frozen_string_literal: true

# One field-recovery micro-turn (design §7.3 O7) for Apply::Ai::Prompt::RecoverField, sent natively. The vocabulary is
# narrower than the Navigator's: click and press only (no navigate / switch_tab / scroll / wait, no fill - the value
# is written by the widget driver, never by the AI).
#
#   actions   <= MAX_ACTIONS items of ResponseSchema::Navigate.action_schema, type click | press
#   reason    short English diagnostic (traced)
#   give_up   true when nothing on the page can make the field accept the value
#
# Engine::RecoverField still checks every ref against the field root / the elements new since the write, and
# Engine::ExecuteAction validates the action itself.
class Apply::Ai::ResponseSchema::RecoverField < ApplyMate::Ai::ResponseSchema::Json
  ACTION_TYPES = %w[click press].freeze
  MAX_ACTIONS = 3

  def self.kind
    :navigate
  end

  def self.json_schema
    {
      type: 'object',
      required: %w[actions reason give_up],
      properties: {
        actions: { type: 'array', maxItems: MAX_ACTIONS,
                   items: Apply::Ai::ResponseSchema::Navigate.action_schema(types: ACTION_TYPES) },
        reason: { type: 'string' },
        give_up: { type: 'boolean' }
      },
      additionalProperties: false
    }
  end

  def self.format_instructions
    <<~INSTRUCTIONS
      Response format:
      Return one JSON object with exactly these keys:
      {"actions": [{"type": "click"|"press", "ref": "<fN:eM>", "key": #{Apply::Ai::ResponseSchema::Navigate::KEYS.map { |key| %("#{key}") }.join('|')}|null,
                    "index": null, "max_ms": null}],
       "reason": "<one short English sentence>", "give_up": true|false}
      At most #{MAX_ACTIONS} actions, only on refs listed in FIELD ELEMENTS. "key" is set for press only.
      "give_up": true (and no actions) when nothing listed can make the field accept the value.
      Wrap the JSON in a ```json code block. No extra text outside the code block.
    INSTRUCTIONS
  end
end
