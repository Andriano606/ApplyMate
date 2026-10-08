# frozen_string_literal: true

# Was the application accepted? (design §11.4) Positive evidence first, from the platform's success_evidence:
#
#   deterministic signals  success_text (a `texts` pattern in the form root's text or in what replaced it),
#                          url_match (a `url_patterns` pattern on the session / a frame URL),
#                          submit_request (a request after the claim matching submit_request[:url], 2xx, whose JSON
#                          body passes body_ok; an unparsable body is not ok)
#   AI corroboration       +1 only when at least one deterministic signal holds and exactly one more signal decides
#                          the verdict (it is not asked when the deterministic count already suffices or one more could
#                          not reach min_signals), the AI integration is not browser_backed (no second browser while
#                          the lease is open) and the AI says submitted with confidence >= AI_MIN_CONFIDENCE quoting
#                          text that is really on the page. The AI never counts alone and its failure never fails the
#                          verify (traced).
#
# Verdict: :submitted when the signals reach success_evidence[:min_signals]; :rejected (definitive: Stage::Verify
# releases the claim) only on proof that nothing was accepted: the form is still there, known fields are invalid, no
# request since the claim is still in flight (a slow submit may land after the wait) AND every request since the claim
# got a 4xx (a transport failure, a 3xx after a POST or a 5xx may have been accepted upstream); :unknown otherwise
# (-> submit_unverified for the user to resolve).
#
# model = Verdict(status, evidence) with a small evidence summary (no page text).
class Apply::Operation::Engine::VerifySubmit < ApplyMate::Operation::Base
  Verdict = Data.define(:status, :evidence)
  AI_MIN_CONFIDENCE = 0.8
  # Seconds the page gets, after the :submit settle, to show the deterministic signals. A submit may send its request
  # well after the click (a reCAPTCHA token first; ~1.2 s on the fixture), past the settle's quiet window. Polled
  # through session.wait_until, so the wait ends at min(EVIDENCE_WAIT, run deadline) when the signals never come.
  EVIDENCE_WAIT = 20

  def perform!(ctx:, **)
    skip_authorize
    @ctx = ctx
    @spec = ctx.platform.success_evidence
    await_signals
    evidence = Apply::Operation::Engine::CollectSubmitEvidence.call(ctx:).model
    signals = deterministic_signals(evidence)
    count = signals.values.count(true)
    signals['ai'] = count.positive? && count == min_signals - 1 && ai_corroborates?(evidence)
    count += 1 if signals['ai']
    self.model = Verdict.new(status: status(count, evidence), evidence: summary(signals, count, evidence))
  end

  private

  attr_reader :ctx, :spec

  def min_signals
    spec.fetch(:min_signals, 1)
  end

  def await_signals
    ctx.session.wait_until(timeout: ctx.clamp(EVIDENCE_WAIT)) do
      evidence = Apply::Operation::Engine::CollectSubmitEvidence.call(ctx:, field_errors: false).model
      deterministic_signals(evidence).values.count(true) >= min_signals
    end
  end

  def deterministic_signals(evidence)
    { 'success_text' => success_text?(evidence), 'url_match' => url_match?(evidence),
      'submit_request' => submit_request_ok?(evidence) }
  end

  def status(count, evidence)
    return :submitted if count >= min_signals
    return :rejected if rejected?(evidence)

    :unknown
  end

  def rejected?(evidence)
    evidence.form_present && evidence.field_errors.any? && evidence.in_flight.zero? &&
      evidence.requests.all? { |record| record[:status].to_i.between?(400, 499) }
  end

  def success_text?(evidence)
    Array(spec[:texts]).any? { |pattern| pattern.match?(evidence.text) }
  end

  def url_match?(evidence)
    Array(spec[:url_patterns]).any? { |pattern| evidence.urls.any? { |url| pattern.match?(url) } }
  end

  def submit_request_ok?(evidence)
    request = spec[:submit_request]
    return false if request.nil?

    mutations_2xx(evidence).any? { |record| request[:url].match?(record[:url].to_s) && body_ok?(request[:body_ok], record[:body]) }
  end

  def body_ok?(check, body)
    return true if check.nil?

    check.call(JSON.parse(body.to_s)) == true
  rescue JSON::ParserError, TypeError, NoMethodError
    false
  end

  def mutations_2xx(evidence)
    evidence.requests.select { |record| record[:status].to_i.between?(200, 299) }
  end

  def ai_corroborates?(evidence)
    integration = ctx.apply.ai_integration
    return false if integration.nil? || AiIntegration::PROVIDER_CLIENTS.fetch(integration.provider).supports?(:browser_backed)

    # The AI sees (and quotes) the redacted text only.
    text = Apply::Operation::Engine::Redact.call(text: evidence.text, apply: ctx.apply,
                                                 max_length: Apply::Operation::Engine::CollectSubmitEvidence::TEXT_LIMIT).model
    verdict = ApplyMate::Ai::AiHandler.call(prompt_instance: Apply::Ai::Prompt::VerifySubmit.new(text:),
                                            response_schema_class: Apply::Ai::ResponseSchema::VerifySubmit,
                                            ai_integration: integration)
    verdict[:submitted] == true && verdict[:confidence].to_f >= AI_MIN_CONFIDENCE && quoted?(text, verdict[:quote])
  rescue StandardError => e
    ctx.trace(:verify_ai_failed, error: e.class.name)
    Rails.error.report(e, handled: true, context: { apply: ctx.apply.hashid, stage: 'verify' })
    false
  end

  def quoted?(text, quote)
    wanted = quote.to_s.squish.downcase
    wanted.present? && text.to_s.squish.downcase.include?(wanted)
  end

  def summary(signals, count, evidence)
    { 'signals' => signals, 'count' => count, 'min_signals' => min_signals,
      'form_present' => evidence.form_present, 'field_errors' => evidence.field_errors.keys,
      'mutations_2xx' => mutations_2xx(evidence).size, 'requests' => evidence.requests.size,
      'in_flight' => evidence.in_flight }
  end
end
