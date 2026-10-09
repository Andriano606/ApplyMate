# frozen_string_literal: true

# An apply step's `ensure` must get to ApplyMate::Client::Browser::Session#close (the lease DELETE) on SIGTERM,
# so workers get 30 s to finish in-flight jobs before they are killed. The Kamal stop timeout of the apply_worker
# accessory/role is >= 40 s, above this value.
Rails.application.config.solid_queue.shutdown_timeout = 30.seconds
