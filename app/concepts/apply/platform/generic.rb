# frozen_string_literal: true

# The adapter of everything Detect does not recognise (Match.generic). No signals, no providers: in phase 3a an
# unknown platform keeps the legacy external path; the AI Navigator that reaches its form arrives in phase 3b.
class Apply::Platform::Generic < Apply::Platform::Base
  def self.key
    Apply::Operation::Engine::Detect::Match::GENERIC_KEY
  end

  # Only the AI can tell this form has rendered.
  def readiness
    :ai_only
  end
end
