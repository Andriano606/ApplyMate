# frozen_string_literal: true

# Shared helpers for the lifecycle transitions (RecordHalt, Finish, HaltUnowned); the halt outcome itself is
# Lifecycle::Decide. Every owned transition goes through FencedUpdate; every transition ends with one Broadcast.
class Apply::Operation::Engine::Lifecycle::Base < ApplyMate::Operation::Base
  include ApplyMate::Logging

  private

  def transition!(ctx, attributes)
    Apply::Operation::Engine::FencedUpdate.call(ctx:, attributes:)
  end

  def broadcast(apply)
    Apply::Operation::Engine::Broadcast.call(apply:)
  end
end
