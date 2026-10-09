# frozen_string_literal: true

# The only door to the AI inside the apply engine (design §6.3, AiBudget#call). In this order, all mandatory:
#   1. ctx.check_fence!
#   2. capabilities: none is required. Every integration may drive every caller (owner decision 2026-10-09): a client
#      without native :json_schema runs in text mode (format_instructions + ResponseSchema::Json parsing), a
#      browser_backed one (GeminiScraping) may run inside a lease, its one local Chrome per process bounded by the
#      client's own slot. Images without :vision are dropped (traced), never an error.
#   3. the budget: ONE UPDATE ... RETURNING bumps ai_calls (this attempt) and ai_calls_total (the apply's life) on the row
#      the run owns (id AND run_token, primary key); 0 rows = fenced. Over the lifetime cap -> Halt(:ai_lifetime_cap),
#      over the attempt cap -> Halt(:ai_budget_exhausted). The counters are incremented SQL-side: the heartbeat thread
#      and other fibers write the same row, a Ruby read-modify-write would lose their updates.
#   4. the HTTP timeout: the client's declared latency for the kind (Client::Base.call_seconds: the kind's
#      Request::TIMEOUTS for an API, 240 s for GeminiScraping), capped by the caller's own budget (`timeout:`, e.g.
#      RecoverField's), never past the run's remaining time minus AI_RESERVE (what the step needs after the call). Less than
#      MIN_TIMEOUT left -> Halt(:deadline).
#   5. AiHandler.complete with client retries: 0; CallAi owns the retry. A transient provider failure
#      (Client::Base::Unavailable: 429 rate limit, 5xx, timeout) is retried at most TRANSIENT_RETRIES times, sleeping
#      RETRY_BACKOFF * 2**(n-1) seconds clamped so the retry still gets MIN_TIMEOUT + AI_RESERVE of the run (or scope)
#      deadline; with less left, or once the retries are spent, Unavailable propagates (Runner: Halt(:capacity)). The
#      fence is re-checked after each sleep. A retry is the same budgeted call (not re-counted). QuotaExhausted is never
#      retried (Runner: Halt(:ai_quota_exhausted)).
#   6. tokens are added SQL-side to applies and to the running step's row, and traced `ai_call`,
#      for a schema-invalid answer too (InvalidResponse#usage; traced with invalid: true) before it propagates.
# InvalidResponse / EmptyResponse propagate: the caller decides about its single retry, the Runner maps what is left.
#
# model = the parsed answer (schema.extract, indifferent access); result[:ai_calls] = this attempt's count after the call
class Apply::Operation::Engine::CallAi < ApplyMate::Operation::Base
  MAX_AI_CALLS_PER_ATTEMPT = 30
  MAX_AI_CALLS_PER_APPLY = 90
  # Seconds of the run kept for the step after the call.
  AI_RESERVE = 30
  MIN_TIMEOUT = 5
  # Bounded retry of a transient provider failure (step 5): what stops it is the count and the deadline.
  TRANSIENT_RETRIES = 2
  RETRY_BACKOFF = 2

  COUNT_SQL = <<~SQL.squish
    UPDATE applies
       SET ai_calls = ai_calls + 1, ai_calls_total = ai_calls_total + 1, updated_at = now()
     WHERE id = $1 AND run_token = $2
    RETURNING ai_calls, ai_calls_total
  SQL

  # The kind every latency allowance is measured on.
  BASE_KIND = :navigate

  # Latency-aware sizing, the ONE place it is computed. A budget planned around `calls` AI calls (Navigator, field
  # recovery, a browser scope, a run) gets `allowance` extra seconds for the integration: calls * slowdown, where
  # slowdown is what one call of the client takes beyond the fast default (0 for an API, 180 s for GeminiScraping).
  def self.allowance(ai_integration, calls)
    calls * slowdown(AiIntegration::PROVIDER_CLIENTS.fetch(ai_integration.provider))
  end

  # The largest allowance any provider may get: for windows fixed at class load (Apply::Job::Apply's concurrency key).
  def self.max_allowance(calls)
    calls * AiIntegration::PROVIDER_CLIENTS.values.map { |client_class| slowdown(client_class) }.max
  end

  def self.slowdown(client_class)
    (client_class.call_seconds(BASE_KIND) - ApplyMate::Ai::Request::TIMEOUTS.fetch(BASE_KIND)).clamp(0, nil)
  end

  def perform!(ctx:, prompt:, schema:, images: [], system: nil, timeout: nil, **)
    skip_authorize
    ctx.check_fence!
    integration = ctx.apply.ai_integration
    client_class = AiIntegration::PROVIDER_CLIENTS.fetch(integration.provider)
    images = usable_images(ctx, client_class, images)
    counts = count_call(ctx)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    outcome = complete_with_retries(ctx, client_class, schema, timeout) do |call_timeout|
      ApplyMate::Ai::AiHandler.complete(
        prompt_instance: prompt, response_schema_class: schema, ai_integration: integration,
        request_options: { timeout: call_timeout, retries: 0, system:, images: }
      )
    rescue ApplyMate::Ai::ResponseSchema::Json::InvalidResponse => e
      account(ctx, schema, e.usage, started, counts, invalid: true) if e.usage
      raise
    end
    account(ctx, schema, outcome.usage, started, counts)
    result[:ai_calls] = counts[:ai_calls]
    self.model = outcome.data
  end

  private

  # Yields the call's HTTP timeout (recomputed per try: the run's remaining time shrinks); retries Unavailable (step 5).
  def complete_with_retries(ctx, client_class, schema, cap)
    retries = 0
    begin
      yield timeout_for(ctx, client_class, schema, cap)
    rescue ApplyMate::Ai::Client::Base::Unavailable => e
      wait = retry_wait(ctx, retries += 1)
      raise if wait.nil?

      ctx.trace(:ai_retry, attempt: retries, wait:, error: e.message.truncate(200))
      sleep(wait)
      ctx.check_fence!
      retry
    end
  end

  # Seconds to sleep before retry number `retry_number`, or nil when the retries are spent or the deadline leaves no
  # room for one more call after the sleep.
  def retry_wait(ctx, retry_number)
    return if retry_number > TRANSIENT_RETRIES

    room = (ctx.remaining - AI_RESERVE - MIN_TIMEOUT).floor
    return if room <= 0

    [ RETRY_BACKOFF * (2**(retry_number - 1)), room ].min
  end

  # Tokens and the `ai_call` trace for every call that returned, a schema-invalid answer included (`invalid: true`).
  def account(ctx, schema, usage, started, counts, invalid: false)
    ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
    record_tokens(ctx, usage)
    ctx.trace(:ai_call, kind: schema.kind.to_s, input_tokens: usage.input_tokens, output_tokens: usage.output_tokens, ms:,
                        **counts, **(invalid ? { invalid: true } : {}))
  end

  # Returns the images the request may carry.
  def usable_images(ctx, client_class, images)
    return images if images.empty? || client_class.supports?(:vision)

    ctx.trace(:ai_images_dropped, count: images.size)
    []
  end

  def count_call(ctx)
    row = Apply.with_connection { |connection| connection.exec_query(COUNT_SQL, 'Apply::CallAi', binds(ctx)) }.first
    fence!(ctx) if row.nil?
    halt!(:ai_lifetime_cap, "#{row['ai_calls_total']} calls") if row['ai_calls_total'] > MAX_AI_CALLS_PER_APPLY
    halt!(:ai_budget_exhausted, "#{row['ai_calls']} calls in this attempt") if row['ai_calls'] > MAX_AI_CALLS_PER_ATTEMPT
    { ai_calls: row['ai_calls'], ai_calls_total: row['ai_calls_total'] }
  end

  def binds(ctx)
    [ ActiveRecord::Relation::QueryAttribute.new('id', ctx.apply.id, ActiveRecord::Type::Integer.new),
      ActiveRecord::Relation::QueryAttribute.new('run_token', ctx.run_token, ActiveRecord::Type::String.new) ]
  end

  def fence!(ctx)
    ctx.fence!
    raise Apply::Operation::Engine::Fenced, "apply=#{ctx.apply.id} run_token=#{ctx.run_token}"
  end

  def timeout_for(ctx, client_class, schema, cap)
    timeout = [ client_class.call_seconds(schema.kind), cap, (ctx.remaining - AI_RESERVE).floor ].compact.min
    halt!(:deadline, 'no time left for an AI call') if timeout < MIN_TIMEOUT
    timeout
  end

  # Adds the tokens to the apply and to the running step row; a provider that reports none counts as 0.
  def record_tokens(ctx, usage)
    input = usage.input_tokens.to_i
    output = usage.output_tokens.to_i
    sql = [ 'ai_input_tokens = ai_input_tokens + ?, ai_output_tokens = ai_output_tokens + ?', input, output ]
    Apply.where(id: ctx.apply.id).update_all(sql)
    step = ctx.scratch.step_record
    ApplyStep.where(id: step.id).update_all(sql) if step
  end

  def halt!(code, detail)
    raise Apply::Operation::Engine::Halt.new(code, detail:)
  end
end
