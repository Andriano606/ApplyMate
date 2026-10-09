# frozen_string_literal: true

# The single redactor for anything the engine stores or shows from a run (design §13.2): failure.detail,
# apply_steps.error_detail, result, traces and failure artifacts. Nil-safe; returns at most
# `max_length` characters (default MAX_LENGTH; failure-artifact HTML passes a larger one). Categories, in order:
#   1. Cookie / Set-Cookie / Authorization header lines are dropped
#   2. credentials are masked by ApplyMate::Ai::Client::Base.scrub (the one credential scrubber): key / api_key /
#      apikey / *token / signature / sig parameter values and bare Google API keys (AIza...), then the session
#      parameters csrfmiddlewaretoken / sessionid / code (a provider error message carries its request URL: Gemini's
#      has ?key=<API key>)
#   3. the apply's own secrets are replaced by placeholders: source profile session id, user email
#   4. any other email address and phone-like digit run is replaced by a placeholder
class Apply::Operation::Engine::Redact < ApplyMate::Operation::Base
  MAX_LENGTH = 2_000
  HEADER_LINE = /^[ \t]*(?:cookie|set-cookie|authorization)[ \t]*:.*(?:\r?\n|\z)/i
  SESSION_PARAM = /(csrfmiddlewaretoken|sessionid|code)=[^;&?#,"'\s]+/i
  EMAIL = /[\w.+-]+@[\w-]+(?:\.[\w-]+)+/
  PHONE = /\+?\d[\d\s().-]{8,}\d/
  MIN_SECRET_LENGTH = 6 # a blank or 1-char "session id" must not rewrite every matching character

  def perform!(text:, apply: nil, max_length: MAX_LENGTH, **)
    skip_authorize
    return if text.nil?

    redacted = ApplyMate::Ai::Client::Base.scrub(text.to_s.gsub(HEADER_LINE, '')).gsub(SESSION_PARAM, '\1=[REDACTED]')
    self.model = generic(facts(redacted, apply)).truncate(max_length)
  end

  private

  def facts(text, apply)
    return text if apply.nil?

    { '{{fact.session_id}}' => apply.source_profile&.session_id, '{{fact.email}}' => apply.user&.email }
      .reduce(text) { |memo, (placeholder, secret)| secret.to_s.length >= MIN_SECRET_LENGTH ? memo.gsub(secret, placeholder) : memo }
  end

  def generic(text)
    text.gsub(EMAIL, '{{email}}').gsub(PHONE, '{{phone}}')
  end
end
