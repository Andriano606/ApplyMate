# frozen_string_literal: true

# Background proxy validator. Run it recurringly (e.g. every few minutes) so it
# keeps churning through the untested proxies, promoting the live ones into the
# "working" tier that SyncVacancies actually uses. The working pool grows over time
# and sync runs get faster.
class Proxy::Job::Validate < ApplicationJob
  queue_as :default

  limits_concurrency to: 1, key: 'proxy_validate'

  def perform(limit: Proxy::Operation::Validate::DEFAULT_LIMIT, scope: :untested)
    Proxy::Operation::Validate.call(limit: limit, scope: scope)
  end
end
