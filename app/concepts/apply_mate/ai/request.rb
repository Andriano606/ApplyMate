# frozen_string_literal: true

# One AI call, provider-neutral. Built by ApplyMate::Ai::AiHandler (via Request.for) and
# handed to ApplyMate::Ai::Client::*#complete, which maps it onto its own wire format.
#
#   system            String or nil — system instruction (Gemini system_instruction, Ollama system message)
#   messages          Array of { role: 'user' | 'model', content: String }
#   images            Array of { mime_type: String, data: <base64 String> } — always empty in phase 0;
#                     the field exists so the client API does not change again when screenshots arrive
#   json_schema       Hash (JSON-Schema subset) or nil — sent natively only to clients that declare
#                     the :json_schema capability; others rely on format_instructions text alone
#   timeout           Integer seconds — HTTP timeout for API clients
#   max_output_tokens Integer — cap on the visible answer
#   thinking_budget   Integer — reasoning tokens allowed on top of max_output_tokens. Thinking models
#                     (Gemini 2.5+, Ollama qwen3/deepseek-r1) spend their reasoning from the same
#                     provider-side cap, so clients send max_output_tokens + thinking_budget as that
#                     cap (Gemini max_output_tokens, Ollama num_predict); Gemini also bounds thinking
#                     itself with thinking_config.thinking_budget. Without this a verify answer can
#                     come back empty with finishReason MAX_TOKENS after the form was submitted.
ApplyMate::Ai::Request = Data.define(:system, :messages, :images, :json_schema, :timeout, :max_output_tokens,
                                     :thinking_budget)

# Reopened (not `Data.define do … end`) so the constants are scoped to Request, not to ApplyMate::Ai.
class ApplyMate::Ai::Request
  KINDS = %i[navigate answers verify cv].freeze

  # Output cap per request kind: navigation decisions and submit verification are short JSON;
  # form answers carry a cover letter; a CV is a full HTML document.
  MAX_OUTPUT_TOKENS = { navigate: 1_024, answers: 4_096, verify: 512, cv: 8_192 }.freeze

  # Reasoning budget per request kind, on top of MAX_OUTPUT_TOKENS. Every value is >= 512, the
  # smallest non-zero thinking_budget all Gemini 2.5 models accept (flash-lite's floor; pro's is 128).
  THINKING_BUDGETS = { navigate: 1_024, answers: 2_048, verify: 512, cv: 2_048 }.freeze

  # HTTP timeout (seconds) per request kind. Without one a hung provider blocks an apply worker thread.
  TIMEOUTS = { navigate: 60, answers: 90, verify: 30, cv: 180 }.freeze

  # Provider-side output cap: the visible answer plus the reasoning that precedes it.
  def output_token_limit
    max_output_tokens + thinking_budget
  end

  # Unknown kind raises KeyError on purpose: every ResponseSchema must declare a real kind.
  def self.for(kind:, text:, json_schema: nil, system: nil, images: [])
    new(
      system:,
      messages:          [ { role: 'user', content: text } ],
      images:,
      json_schema:,
      timeout:           TIMEOUTS.fetch(kind),
      max_output_tokens: MAX_OUTPUT_TOKENS.fetch(kind),
      thinking_budget:   THINKING_BUDGETS.fetch(kind)
    )
  end
end
