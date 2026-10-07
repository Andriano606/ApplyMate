# frozen_string_literal: true

# Fail the boot when config/queue.yml violates the queue topology.
#
# Not SolidQueue.on_start: solid_queue's run_hooks_for wraps every hook in
# `rescue Exception`, so a raise/abort/exit inside the hook is only logged and the
# supervisor keeps running. In an initializer the exception aborts the process
# (bin/jobs, puma and runner alike). The check only parses the file - no DB - so it
# is safe during assets:precompile.
Rails.application.config.after_initialize do
  Apply::Operation::AssertQueueTopology.call
end
