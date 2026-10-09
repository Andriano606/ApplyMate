# frozen_string_literal: true

# Result of ApplyMate::Ai::Client::*#complete: the model's raw text (parsed later by the
# ResponseSchema's `extract`) and the ApplyMate::Ai::Usage it cost.
ApplyMate::Ai::Response = Data.define(:text, :usage)
