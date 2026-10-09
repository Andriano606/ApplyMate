# frozen_string_literal: true

# The "apply" link leads to a messenger chat, not a form: the page the run is on (final URL / top frame) is on a
# MESSENGER_HOSTS domain -> Halt(:external_messenger). Messenger widgets embedded in a frame do not count.
class Apply::Gate::ExternalMessenger < Apply::Gate::Base
  MESSENGER_HOSTS = %w[t.me telegram.me wa.me m.me].freeze

  def self.events
    %i[http_resolved after_goto]
  end

  def call(_ctx, evidence:, **)
    url = main_url(evidence)
    halt!(:external_messenger, detail: host(url)) if on_domain?(host(url), MESSENGER_HOSTS)
  end
end
