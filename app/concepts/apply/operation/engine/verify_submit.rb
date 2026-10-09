# frozen_string_literal: true

# Was the application accepted? (design §11.4) Positive evidence first, from the platform's success_evidence:
#
#   deterministic signals  success_text (a `texts` pattern in the page text: the form root's text, then the rest of
#                          its frame's body),
#                          success_dom (a `selectors` element - the platform's confirmation view - in the form
#                          root's frame),
#                          url_match (a `url_patterns` pattern on the session / a frame URL),
#                          submit_request (a request after the claim matching submit_request[:url], 2xx, whose JSON
#                          body passes body_ok). A 2xx whose body could not be read (NetTracker body_error: dropped /
#                          unreadable / timeout) does NOT count: a GraphQL API answers 200 to a rejected submit too
#                          (Ashby's FormRender), so only the body proves acceptance; the summary records why it was
#                          missing.
#   AI corroboration       +1 only when at least one deterministic signal holds and exactly one more signal decides
#                          the verdict (it is not asked when the deterministic count already suffices or one more could
#                          not reach min_signals), with any AI integration (text mode and browser-backed included),
#                          and the AI says submitted with confidence >= AI_MIN_CONFIDENCE quoting
#                          text that is really on the page. The AI never counts alone and its failure never fails the
#                          verify (traced).
#
# Baseline: the page-side signals (PAGE_SIGNALS: success_text, success_dom, url_match) the page already showed BEFORE
# the click (Engine::SubmitBaseline, ctx.scratch.submit_baseline) never count: an intro saying "Thank you for your
# interest" or a URL path containing "success" proves nothing about the submit. A missing baseline (nil) holds none.
#
# Verdict: :submitted when the signals reach success_evidence[:min_signals] and nothing vetoes - a `failure_selectors`
# element on the page (a "could not submit" view) or the form still present with invalid known fields; :rejected
# (definitive: Stage::Verify releases the claim) only on proof that nothing was accepted: a veto (field errors or a
# failure view), no request since the claim is still in flight (a slow submit may land after the wait) AND every
# request since the claim got a 4xx (a transport failure, a 3xx after a POST or a 5xx - and Ashby's 200 behind its
# failure view - may have been accepted upstream); :unknown otherwise (-> submit_unverified for the user to resolve).
#
# model = Verdict(status, evidence) with a small evidence summary (no page text): per-signal booleans (after the
# baseline), the baseline, counts, the matched success / failure selectors and, per request matching
# submit_request[:url], its status and body state (ok / not_ok / dropped / unreadable / timeout / none).
# Verdict#detail is that summary on one line: Stage::Verify puts it into the Halt detail (apply.failure, the step's
# error_detail) and every non-submitted verdict is logged with it, so a failure stays diagnosable after its artifacts
# are pruned.
class Apply::Operation::Engine::VerifySubmit < ApplyMate::Operation::Base
  include ApplyMate::Logging

  Verdict = Data.define(:status, :evidence) do
    # "signals 1/2 (success_text=no ...); baseline []; requests 3, 2xx 2, in_flight 0; submit_op [200 not_ok]; ..."
    def detail
      flags = evidence['signals'].map { |name, value| "#{name}=#{value ? 'yes' : 'no'}" }.join(' ')
      submit = evidence['submit_op']&.map { |op| "#{op['status'] || 'failed'} #{op['body']}" }
      [ "signals #{evidence['count']}/#{evidence['min_signals']} (#{flags})", "baseline [#{evidence['baseline'].join(', ')}]",
        "requests #{evidence['requests']}, 2xx #{evidence['mutations_2xx']}, in_flight #{evidence['in_flight']}",
        "submit_op #{submit.nil? ? 'not watched' : "[#{submit.join(', ')}]"}",
        "form_present #{evidence['form_present'] ? 'yes' : 'no'}, field_errors #{evidence['field_errors'].size}",
        "success_dom [#{evidence['success_dom'].join(', ')}], failure_dom [#{evidence['failure_dom'].join(', ')}]" ].join('; ')
    end
  end

  AI_MIN_CONFIDENCE = 0.8
  # The signals read off the page (not the network): a baseline taken before the click can hold them.
  PAGE_SIGNALS = %w[success_text success_dom url_match].freeze
  # Seconds the page gets, after the :submit settle, to show the deterministic signals. A submit may send its request
  # well after the click (a reCAPTCHA token first; ~1.2 s on the fixture), past the settle's quiet window. Polled
  # through session.wait_until, so the wait ends at min(EVIDENCE_WAIT, run deadline) when the signals never come.
  EVIDENCE_WAIT = 20

  def perform!(ctx:, **)
    skip_authorize
    @ctx = ctx
    @spec = ctx.platform.success_evidence
    await_signals
    evidence = collect(field_errors: true)
    signals = deterministic_signals(evidence)
    count = signals.values.count(true)
    signals['ai'] = count.positive? && count == min_signals - 1 && !vetoed?(evidence) && ai_corroborates?(evidence)
    count += 1 if signals['ai']
    self.model = Verdict.new(status: status(count, evidence), evidence: summary(signals, count, evidence))
    log("apply=#{ctx.apply.hashid} verify #{model.status}: #{model.detail}", level: :warn) unless model.status == :submitted
  end

  # { 'success_text', 'success_dom', 'url_match' => Boolean } of a CollectSubmitEvidence::Evidence under the platform's
  # success_evidence spec, regardless of any baseline (SubmitBaseline records these before the click).
  def self.page_signals(spec, evidence)
    { 'success_text' => Array(spec[:texts]).any? { |pattern| pattern.match?(evidence.text) },
      'success_dom' => evidence.success_dom.any?,
      'url_match' => Array(spec[:url_patterns]).any? { |pattern| evidence.urls.any? { |url| pattern.match?(url) } } }
  end

  private

  attr_reader :ctx, :spec

  def min_signals
    spec.fetch(:min_signals, 1)
  end

  # Ends early on enough signals or on a failure view (it will not turn into a success).
  def await_signals
    ctx.session.wait_until(timeout: ctx.clamp(EVIDENCE_WAIT)) do
      evidence = collect(field_errors: false)
      evidence.failure_dom.any? || deterministic_signals(evidence).values.count(true) >= min_signals
    end
  end

  def collect(field_errors:)
    Apply::Operation::Engine::CollectSubmitEvidence.call(ctx:, field_errors:, success_selectors: Array(spec[:selectors]),
                                                         failure_selectors: Array(spec[:failure_selectors])).model
  end

  # A page signal counts only when it was false in the baseline.
  def deterministic_signals(evidence)
    page = self.class.page_signals(spec, evidence).to_h { |name, value| [ name, value && baseline.exclude?(name) ] }
    page.merge('submit_request' => submit_request_ok?(evidence))
  end

  def baseline
    @baseline ||= Array(ctx.scratch.submit_baseline)
  end

  def status(count, evidence)
    return :submitted if count >= min_signals && !vetoed?(evidence)
    return :rejected if rejected?(evidence)

    :unknown
  end

  # A failure view, or the form still there with invalid fields: never :submitted.
  def vetoed?(evidence)
    evidence.failure_dom.any? || (evidence.form_present && evidence.field_errors.any?)
  end

  def rejected?(evidence)
    vetoed?(evidence) && evidence.in_flight.zero? &&
      evidence.requests.all? { |record| record[:status].to_i.between?(400, 499) }
  end

  def submit_request_ok?(evidence)
    submit_ops(evidence).any? { |record| body_state(record) == 'ok' }
  end

  # The requests since the claim matching submit_request[:url] ([] when the platform names none).
  def submit_ops(evidence)
    url = spec.dig(:submit_request, :url)
    url.nil? ? [] : evidence.requests.select { |record| url.match?(record[:url].to_s) }
  end

  # ok / not_ok for a 2xx with a body (body_ok decides), the NetTracker body_error when the body is missing, none for
  # a non-2xx or a failed request (not read).
  def body_state(record)
    return 'none' unless record[:status].to_i.between?(200, 299)
    return record[:body_error] || 'unreadable' if record[:body].nil? && spec.dig(:submit_request, :body_ok)

    body_ok?(spec.dig(:submit_request, :body_ok), record[:body]) ? 'ok' : 'not_ok'
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
    # The AI sees (and quotes) the redacted text only.
    text = Apply::Operation::Engine::Redact.call(text: evidence.text, apply: ctx.apply,
                                                 max_length: Apply::Operation::Engine::CollectSubmitEvidence::TEXT_LIMIT).model
    verdict = Apply::Operation::Engine::CallAi.call(ctx:, prompt: Apply::Ai::Prompt::VerifySubmit.new(text:),
                                                    schema: Apply::Ai::ResponseSchema::VerifySubmit).model
    verdict[:submitted] == true && verdict[:confidence].to_f >= AI_MIN_CONFIDENCE && quoted?(text, verdict[:quote])
  rescue Apply::Operation::Engine::Halt, Apply::Operation::Engine::Fenced
    raise
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
    { 'signals' => signals, 'count' => count, 'min_signals' => min_signals, 'baseline' => baseline,
      'form_present' => evidence.form_present, 'field_errors' => evidence.field_errors.keys,
      'mutations_2xx' => mutations_2xx(evidence).size, 'requests' => evidence.requests.size,
      'in_flight' => evidence.in_flight, 'success_dom' => evidence.success_dom, 'failure_dom' => evidence.failure_dom,
      'submit_op' => spec[:submit_request] && submit_ops(evidence).map { |record| { 'status' => record[:status], 'body' => body_state(record) } } }
  end
end
