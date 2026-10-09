# frozen_string_literal: true

# The adapter of everything Detect does not recognise (Match.generic): no signals, no providers. Its form is reached
# by the AI Navigator (Engine::Navigate, from Engine::ReachForm) and accepted only through R2
# (Engine::AssessFormLikeness); readiness is :ai_only, so no deterministic readiness poll ever claims a generic page
# is the form.
#
# success_evidence: two of a thank-you text (uk / en / ru), a thank-you URL fragment and a submit request (a 2xx
# non-GET request after the claim to the form's own registered domain, Engine::CheckOrigin.site_of; any body), or one
# plus the AI's corroboration (Engine::VerifySubmit asks the AI only when one deterministic signal holds: the AI never
# counts alone, design R13). The page signals never count when the page already showed them before the click
# (Engine::SubmitBaseline); the request alone never suffices, since a site may answer 200 to a rejected form.
class Apply::Platform::Generic < Apply::Platform::Base
  SUCCESS_TEXTS = [
    /thank(s| you) for (your )?(applying|application|interest|submission)/i,
    /(your )?application (has been |was )?(successfully )?(submitted|received|sent)/i,
    /we('ve| have) received your (application|cv|resume)/i,
    /we('ll| will) (review|consider) (it|your (application|cv|resume))/i,
    /дякуємо за (ваш[уі]? )?(відгук|заявку|резюме|інтерес)/i,
    /(ваш[уаі]? )?(заявк[уаи]|відгук|резюме|анкет[уаи]) (успішно |було )?(надіслан|отриман|відправлен|прийнят|подан)[аоий]?/i,
    /ми (обов[ʼ'’]язково )?(розглянемо|опрацюємо|зв[ʼ'’]яжемося)/i,
    /спасибо за (ваш[уи]? )?(отклик|заявку|резюме|интерес)/i,
    /(ваш[аи]? )?(заявк[аиу]|отклик|резюме|анкет[аиу]) (успешно |была )?(отправлен|получен|принят|подан)[аоыи]?/i,
    /мы (обязательно )?(рассмотрим|свяжемся)/i
  ].freeze
  # A fragment of the path / query / fragment, never of the host (thank-you.example would match every page there).
  SUCCESS_URLS = [ %r{\Ahttps?://[^/?#]+[/?#].*(thank|success|confirm|received|applied)}i ].freeze

  def self.key
    Apply::Operation::Engine::Detect::Match::GENERIC_KEY
  end

  # Only the AI can tell this form has rendered.
  def readiness
    :ai_only
  end

  def success_evidence
    { texts: SUCCESS_TEXTS, url_patterns: SUCCESS_URLS, submit_request: same_site_request, min_signals: 2 }
  end

  private

  # nil before the form URL is known (no request can be attributed to the form's site then).
  def same_site_request
    site = Apply::Operation::Engine::CheckOrigin.site_of(ctx.form_url)
    site && { url: %r{\Ahttps?://([^/?#]+\.)?#{Regexp.escape(site)}(:\d+)?[/?#]}i }
  end
end
