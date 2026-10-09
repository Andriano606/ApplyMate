# frozen_string_literal: true

# DataDome bot protection (design §9.2): a hop, current URL, script or frame on captcha-delivery.com, or the
# snapshot's captcha list naming it -> Halt(:bot_wall). No retry: the wall does not go away for a headless run.
class Apply::Gate::DataDome < Apply::Gate::Base
  DOMAINS = %w[captcha-delivery.com].freeze

  def self.events
    %i[http_resolved after_goto]
  end

  def call(_ctx, evidence:, snapshot: nil, **)
    urls = evidence.hops + evidence.current_urls + evidence.script_srcs + evidence.iframe_srcs
    walled = urls.any? { |url| on_domain?(host(url), DOMAINS) } ||
             Array(snapshot&.frames).any? { |frame| Array(frame['captcha']).include?('datadome') }
    halt!(:bot_wall, detail: 'datadome') if walled
  end
end
