# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Engine::CallAi do
  subject(:call) { described_class.call(ctx:, prompt:, schema:, **options) }

  let(:apply) { create(:apply) }
  let(:ctx) { engine_context(apply) }
  let(:schema) { Apply::Ai::ResponseSchema::VerifySubmit }
  let(:prompt) { instance_double(ApplyMate::Ai::Prompt::Base, call: 'Was it submitted?') }
  let(:options) { {} }
  let(:gemini) { %r{generativelanguage\.googleapis\.com.*generateContent} }
  let(:answer) { { submitted: true, confidence: 0.9, quote: 'Thank you' }.to_json }

  before { stub_request(:post, gemini).to_return(gemini_json_response(answer, usage: { prompt: 120, candidates: 8, thoughts: 2 })) }

  def counters
    apply.reload.slice(:ai_calls, :ai_calls_total, :ai_input_tokens, :ai_output_tokens).symbolize_keys
  end

  def open_session!
    ctx.open_scope!(:survey, FakeSession.new(html: '', final_url: 'https://example.test/'), 5.minutes.from_now)
  end

  it 'returns the parsed answer' do
    expect(call.model).to include('submitted' => true, 'quote' => 'Thank you')
  end

  it 'counts two sequential calls as 2/2 with one UPDATE ... RETURNING each (no Ruby read-modify-write)' do
    statements = []
    ctx
    allow(Apply.connection).to receive(:exec_query).and_wrap_original do |original, sql, *rest|
      statements << sql
      original.call(sql, *rest)
    end
    2.times { described_class.call(ctx:, prompt:, schema:) }

    expect(statements.grep(/UPDATE applies/).size).to eq(2)
    expect(statements.first).to match(/ai_calls = ai_calls \+ 1, ai_calls_total = ai_calls_total \+ 1.*RETURNING ai_calls, ai_calls_total/)
    expect(counters).to include(ai_calls: 2, ai_calls_total: 2)
  end

  context 'when the answer violates the schema' do
    let(:answer) { { confidence: 'sure' }.to_json }

    it 'still records the tokens it cost and traces the call as invalid before raising' do
      expect { call }.to raise_error(ApplyMate::Ai::ResponseSchema::Json::InvalidResponse) { |error|
        expect(error.usage).to have_attributes(input_tokens: 120, output_tokens: 10)
      }
      expect(counters).to include(ai_calls: 1, ai_input_tokens: 120, ai_output_tokens: 10)
      expect(ctx.scratch.trace.last).to include('event' => 'ai_call', 'invalid' => true, 'input_tokens' => 120)
    end
  end

  it 'traces the call with kind, tokens and counters' do
    call

    expect(ctx.scratch.trace.last).to include('event' => 'ai_call', 'kind' => 'verify', 'input_tokens' => 120,
                                              'output_tokens' => 10, 'ai_calls' => 1, 'ai_calls_total' => 1)
  end

  describe 'budget' do
    it 'raises ai_budget_exhausted on call 31 of an attempt, before any request' do
      ctx
      Apply.where(id: apply.id).update_all(ai_calls: described_class::MAX_AI_CALLS_PER_ATTEMPT)

      expect { call }.to raise_error(Apply::Operation::Engine::Halt) { |halt| expect(halt.code).to eq(:ai_budget_exhausted) }
      expect(a_request(:post, gemini)).not_to have_been_made
    end

    it 'allows call 30' do
      ctx
      Apply.where(id: apply.id).update_all(ai_calls: described_class::MAX_AI_CALLS_PER_ATTEMPT - 1)

      expect(call.model).to be_present
    end

    it 'raises ai_lifetime_cap on call 91 of the apply, checked before the attempt cap' do
      ctx
      Apply.where(id: apply.id).update_all(ai_calls: 40, ai_calls_total: described_class::MAX_AI_CALLS_PER_APPLY)

      expect { call }.to raise_error(Apply::Operation::Engine::Halt) { |halt| expect(halt.code).to eq(:ai_lifetime_cap) }
    end
  end

  describe 'fencing' do
    it 'raises Fenced and fences the context when the run_token rotated' do
      ctx
      rotate_run_token!(apply)

      expect { call }.to raise_error(Apply::Operation::Engine::Fenced)
      expect(ctx).to be_fenced
      expect(a_request(:post, gemini)).not_to have_been_made
    end

    it 'raises Fenced up front for an already fenced context' do
      ctx.fence!

      expect { call }.to raise_error(Apply::Operation::Engine::Fenced)
    end
  end

  describe 'capabilities' do
    # Owner decision 2026-10-09: no integration is refused for its capabilities, inside a lease included.
    context 'with a GeminiScraping integration (browser-backed, no native JSON schema, slow)' do
      let(:client) { instance_double(ApplyMate::Ai::Client::GeminiScraping) }
      let(:requests) { [] }

      before do
        apply.ai_integration.update!(provider: 'gemini_scraping')
        allow(ApplyMate::Ai::Client::GeminiScraping).to receive(:new).and_return(client)
        allow(client).to receive(:complete) do |request|
          requests << request
          ApplyMate::Ai::Response.new(text: "Here you go:\n```json\n#{answer}\n```", usage: ApplyMate::Ai::Usage::UNKNOWN)
        end
      end

      it 'is asked inside a lease (text mode), with its own latency as the timeout and no retries' do
        open_session!

        expect(call.model).to include('submitted' => true)
        expect(requests.sole).to have_attributes(timeout: ApplyMate::Ai::Client::GeminiScraping::CALL_SECONDS, retries: 0)
        expect(counters).to include(ai_calls: 1, ai_input_tokens: 0)
      end

      it 'never runs past the scope: the timeout is clamped to what is left minus AI_RESERVE' do
        ctx.open_scope!(:survey, FakeSession.new(html: '', final_url: 'https://example.test/'), 100.seconds.from_now)

        call
        expect(requests.sole.timeout).to be_between(described_class::MIN_TIMEOUT, 100 - described_class::AI_RESERVE)
      end
    end

    it 'gives an API client the kind timeout (verify: 30 s)' do
      timeouts = []
      allow(ApplyMate::Ai::Client::Gemini).to receive(:new).and_wrap_original do |original, **options|
        original.call(**options).tap do |client|
          allow(client).to receive(:complete).and_wrap_original { |complete, request| timeouts << request.timeout; complete.call(request) }
        end
      end
      call

      expect(timeouts).to eq([ ApplyMate::Ai::Request::TIMEOUTS.fetch(:verify) ])
    end

    it 'drops images for a client without vision, tracing it (Ollama)' do
      apply.ai_integration.update!(provider: 'ollama', host: 'http://ollama.test:11434', model: 'llama3.1')
      stub_request(:post, 'http://ollama.test:11434/api/chat').to_return(ollama_chat_response(answer, prompt_eval_count: 3, eval_count: 4))
      image = { mime_type: 'image/png', data: 'aGk=' }

      expect(described_class.call(ctx:, prompt:, schema:, images: [ image ]).model).to include('submitted' => true)
      expect(ctx.scratch.trace.map { |entry| entry['event'] }).to include('ai_images_dropped')
    end

    it 'sends images and the system prompt to a vision client' do
      image = { mime_type: 'image/png', data: 'aGk=' }
      described_class.call(ctx:, prompt:, schema:, images: [ image ], system: 'Be brief')

      expect(
        a_request(:post, gemini).with do |req|
          body = JSON.parse(req.body)
          body.dig('system_instruction', 'parts', 0, 'text') == 'Be brief' &&
            body.dig('contents', 0, 'parts', 1, 'inline_data', 'data') == 'aGk='
        end
      ).to have_been_made.once
    end
  end

  describe 'timeout' do
    def sent_timeout
      captured = nil
      allow(ApplyMate::Ai::AiHandler).to receive(:complete).and_wrap_original do |original, **kwargs|
        captured = kwargs[:request_options]
        original.call(**kwargs)
      end
      call
      captured
    end

    it 'uses the kind timeout while the run has time; the client never retries (CallAi owns the retry)' do
      expect(sent_timeout).to include(timeout: 30, retries: 0)
    end

    it 'is clamped to the remaining time minus the reserve inside a lease' do
      open_session!
      ctx.scratch.scope_deadline = 45.seconds.from_now

      expect(sent_timeout).to include(timeout: be_between(13, 15), retries: 0)
    end

    it 'halts with deadline when less than MIN_TIMEOUT is left after the reserve' do
      ctx.scratch.scope_deadline = 33.seconds.from_now

      expect { call }.to raise_error(Apply::Operation::Engine::Halt) { |halt| expect(halt.code).to eq(:deadline) }
      expect(a_request(:post, gemini)).not_to have_been_made
    end
  end

  describe 'token accounting' do
    it 'adds the tokens to the apply SQL-side across calls' do
      2.times { described_class.call(ctx:, prompt:, schema:) }

      expect(counters).to include(ai_input_tokens: 240, ai_output_tokens: 20)
    end

    it 'adds them to the running step row too' do
      step = ApplyStep.create!(apply:, attempt: apply.attempt, key: 'answer', stage: 'answer', position: 0, state: :running,
                               started_at: Time.current)
      ctx.scratch.step_record = step
      call

      expect(step.reload).to have_attributes(ai_input_tokens: 120, ai_output_tokens: 10)
    end

    it 'counts an unreported usage as 0' do
      stub_request(:post, gemini).to_return(gemini_json_response(answer))
      call

      expect(counters).to include(ai_input_tokens: 0, ai_output_tokens: 0, ai_calls: 1)
    end
  end

  describe 'transient provider failures' do
    let(:rate_limited) { { status: 429, body: { error: { code: 429, status: 'RESOURCE_EXHAUSTED' } }.to_json } }

    before { allow_any_instance_of(described_class).to receive(:sleep) } # rubocop:disable RSpec/AnyInstance

    def retries_traced
      ctx.scratch.trace.select { |entry| entry['event'] == 'ai_retry' }
    end

    it 'retries a 429 inside a lease with backoff and returns the answer, counted as one call' do
      open_session!
      stub_request(:post, gemini).to_return(rate_limited, { status: 503, body: '' },
                                            gemini_json_response(answer, usage: { prompt: 10, candidates: 1 }))

      expect(call.model).to include('submitted' => true)
      expect(a_request(:post, gemini)).to have_been_made.times(3)
      expect(retries_traced.map { |entry| entry.slice('attempt', 'wait') })
        .to eq([ { 'attempt' => 1, 'wait' => 2 }, { 'attempt' => 2, 'wait' => 4 } ])
      expect(counters).to include(ai_calls: 1, ai_input_tokens: 10)
    end

    it 'stops after TRANSIENT_RETRIES and raises Unavailable (Runner: capacity), the API key scrubbed' do
      stub_request(:post, gemini).to_return(rate_limited)

      expect { call }.to raise_error(ApplyMate::Ai::Client::Base::Unavailable) { |error| expect(error.message).not_to match(/AIza|key=(?!\[)/) }
      expect(a_request(:post, gemini)).to have_been_made.times(described_class::TRANSIENT_RETRIES + 1)
      expect(Apply::Operation::Engine::Run.as_halt(ApplyMate::Ai::Client::Base::Unavailable.new('x')).code).to eq(:capacity)
    end

    it 'clamps the backoff to the deadline and gives up when no call would fit after it' do
      ctx.scratch.scope_deadline = (described_class::AI_RESERVE + described_class::MIN_TIMEOUT + 1.5).seconds.from_now
      stub_request(:post, gemini).to_return(rate_limited)

      expect { call }.to raise_error(ApplyMate::Ai::Client::Base::Unavailable)
      expect(retries_traced.pluck('wait')).to all(be <= 1)
    end

    it 'never retries an exhausted daily quota: QuotaExhausted, mapped to the needs_human ai_quota_exhausted halt' do
      body = { error: { code: 429, status: 'RESOURCE_EXHAUSTED', message: 'You exceeded your current quota',
                        details: [ { violations: [ { quotaId: 'GenerateRequestsPerDayPerProjectPerModel-FreeTier' } ] },
                                   { retryDelay: '67247s' } ] } }.to_json
      stub_request(:post, gemini).to_return(status: 429, body:)

      expect { call }.to raise_error(ApplyMate::Ai::Client::Base::QuotaExhausted) { |error|
        halt = Apply::Operation::Engine::Run.as_halt(error)
        expect([ halt.code, halt.state ]).to eq(%i[ai_quota_exhausted needs_human])
      }
      expect(a_request(:post, gemini)).to have_been_made.once
    end
  end

  describe 'a bad answer' do
    it 'propagates InvalidResponse (the call still counted)' do
      stub_request(:post, gemini).to_return(gemini_json_response('not json'))

      expect { call }.to raise_error(ApplyMate::Ai::ResponseSchema::Json::InvalidResponse)
      expect(counters).to include(ai_calls: 1)
    end
  end

  describe 'latency allowance' do
    it 'is 0 for API clients and calls * (240 - 60) s for GeminiScraping' do
      expect(described_class.allowance(build(:ai_integration, provider: 'gemini'), 4)).to eq(0)
      expect(described_class.allowance(build(:ai_integration, provider: 'ollama'), 4)).to eq(0)
      expect(described_class.allowance(build(:ai_integration, provider: 'gemini_scraping'), 4)).to eq(4 * 180)
    end

    it 'takes the slowest provider for max_allowance' do
      expect(described_class.max_allowance(8)).to eq(8 * 180)
    end
  end
end
