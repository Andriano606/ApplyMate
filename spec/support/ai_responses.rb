# frozen_string_literal: true

# WebMock `to_return` payloads for the AI providers. Included in every spec (rails_helper).
#
#   stub_request(:post, /generativelanguage\.googleapis\.com.*generateContent/)
#     .to_return(gemini_json_response('```json\n{"key":"value"}\n```'))
#   stub_request(:post, 'http://ollama.test:11434/api/chat')
#     .to_return(ollama_chat_response('{"answer":"hi"}', prompt_eval_count: 12, eval_count: 3))
module AiResponses
  # usage: { prompt:, candidates:, thoughts: } token counts → usageMetadata (omitted when nil).
  def gemini_json_response(text, usage: nil)
    body = { candidates: [ { content: { parts: [ { text: } ] } } ] }
    if usage
      body[:usageMetadata] = {
        promptTokenCount:     usage[:prompt],
        candidatesTokenCount: usage[:candidates],
        thoughtsTokenCount:   usage[:thoughts]
      }.compact
    end

    { status: 200, body: body.to_json, headers: { 'Content-Type' => 'application/json' } }
  end

  # Non-streaming /api/chat body (`stream: false` → one JSON line).
  def ollama_chat_response(text, prompt_eval_count:, eval_count:)
    body = {
      model:             'llama3.1',
      created_at:        '2026-01-01T00:00:00Z',
      message:           { role: 'assistant', content: text },
      done:              true,
      done_reason:       'stop',
      prompt_eval_count:,
      eval_count:
    }

    { status: 200, body: body.to_json, headers: { 'Content-Type' => 'application/json' } }
  end
end
