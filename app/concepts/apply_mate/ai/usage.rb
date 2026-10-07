# frozen_string_literal: true

# Token usage reported by a provider for one ApplyMate::Ai::Request. Either count may be nil
# when the provider does not report it (GeminiScraping always returns UNKNOWN).
ApplyMate::Ai::Usage = Data.define(:input_tokens, :output_tokens)

class ApplyMate::Ai::Usage
  UNKNOWN = new(input_tokens: nil, output_tokens: nil)
end
