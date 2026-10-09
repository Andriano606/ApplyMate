# frozen_string_literal: true

# This run no longer owns the Apply row (applies.run_token rotated, or the heartbeat stopped past the
# deadline grace). Raised by Apply::Operation::Engine::FencedUpdate and Context#check_fence!; the Runner
# exits without writing anything further.
class Apply::Operation::Engine::Fenced < StandardError; end
