# frozen_string_literal: true

# Apply::Operation::Engine::StartContext matched no row: the Apply is not queued / waiting_capacity, or a
# live run (fresh heartbeat) owns it. The Runner logs and returns; the job finishes normally.
class Apply::Operation::Engine::NotStartable < StandardError; end
