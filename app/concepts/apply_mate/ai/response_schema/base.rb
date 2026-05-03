# frozen_string_literal: true

class ApplyMate::Ai::ResponseSchema::Base
  # The formatting instruction to be injected into PROMPT_TEMPLATE
  def self.format_instructions
    raise NotImplementedError
  end

  # Extracts and parses JSON from the AI's string response
  def self.extract(raw_response)
    raise NotImplementedError
  end
end
