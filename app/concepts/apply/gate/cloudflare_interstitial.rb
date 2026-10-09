# frozen_string_literal: true

# A Cloudflare interstitial the browser could not get past: Goto already waited WaitPastCloudflare (40 s), so a page
# that still shows it is a wall -> Halt(:bot_wall, detail: 'cloudflare'). Main frame only (an embedded Cloudflare
# widget in a frame is a captcha, VisibleCaptcha's business). The marker check is
# ApplyMate::Client::Response.cloudflare_interstitial?: the one predicate, applied to the title and the outline text.
class Apply::Gate::CloudflareInterstitial < Apply::Gate::Base
  def self.events
    %i[after_goto]
  end

  def call(_ctx, snapshot: nil, **)
    frame = snapshot&.frames&.first
    return if frame.nil?

    halt!(:bot_wall, detail: 'cloudflare') if interstitial?(frame)
  end

  private

  def interstitial?(frame)
    [ frame['title'], Array(frame['outline']).join("\n") ].any? do |text|
      ApplyMate::Client::Response.cloudflare_interstitial?(text)
    end
  end
end
