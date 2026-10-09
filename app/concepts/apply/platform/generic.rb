# frozen_string_literal: true

# The adapter of everything Detect does not recognise (Match.generic): no signals, no providers. Its form is reached
# by the AI Navigator (Engine::Navigate, from Engine::ReachForm) and accepted only through R2
# (Engine::AssessFormLikeness); readiness is :ai_only, so no deterministic readiness poll ever claims a generic page
# is the form.
#
# success_evidence: a thank-you text (uk / en / ru) or a thank-you URL fragment, two of them, or one plus the AI's
# corroboration (Engine::VerifySubmit asks the AI only when one deterministic signal holds: the AI never counts alone,
# design R13).
class Apply::Platform::Generic < Apply::Platform::Base
  SUCCESS_TEXTS = [
    /thank(s| you) for (your )?(applying|application|interest|submission)/i,
    /(your )?application (has been |was )?(successfully )?(submitted|received|sent)/i,
    /we('ve| have) received your (application|cv|resume)/i,
    /дякуємо за (ваш[уі]? )?(відгук|заявку|резюме|інтерес)/i,
    /(ваш[уа] )?(заявк[уа]|відгук|резюме) (успішно )?(надіслано|отримано|відправлено|прийнято)/i,
    /спасибо за (ваш[уи]? )?(отклик|заявку|резюме|интерес)/i,
    /(ваш[аи] )?(заявка|отклик|резюме) (успешно )?(отправлен[аоы]?|получен[аоы]?|принят[аоы]?)/i
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
    { texts: SUCCESS_TEXTS, url_patterns: SUCCESS_URLS, submit_request: nil, min_signals: 2 }
  end
end
