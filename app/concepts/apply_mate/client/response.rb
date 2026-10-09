# frozen_string_literal: true

module ApplyMate
  module Client
    # Shared HTTP response shape for every ApplyMate::Client (AsyncHttp, ImpersonateHttp,
    # Browser) so the struct can't drift between clients, plus the Cloudflare-challenge /
    # reachability checks the proxy validator and the sync probe both rely on.
    Response = Struct.new(:body, :headers, :status, :final_url)

    # Reopened to attach the helpers: a `Struct.new do … end` block would scope the
    # CLOUDFLARE_MARKERS constant to ApplyMate::Client (lexical), not to Response.
    class Response
      # Substrings meaning Cloudflare is still showing its "Just a moment…" JS challenge
      # instead of the real page.
      CLOUDFLARE_MARKERS = [ 'Just a moment', 'challenge-platform', 'cf-chl-', '_cf_chl_opt' ].freeze

      # In a rendered page 'challenge-platform' alone is not a challenge: Cloudflare injects its bot-management
      # script (/cdn-cgi/challenge-platform/scripts/jsd/main.js) into ordinary 200 pages. The interstitial
      # always carries 'Just a moment' (title) or the cf-chl-/_cf_chl_opt markers as well.
      INTERSTITIAL_MARKERS = (CLOUDFLARE_MARKERS - [ 'challenge-platform' ]).freeze

      # The one marker check for HTTP bodies; Response instances delegate to it.
      def self.cloudflare_challenge?(body)
        markers_in?(body, CLOUDFLARE_MARKERS)
      end

      # The same check for a page a browser rendered (Browser::Operation::WaitPastCloudflare): title or HTML.
      def self.cloudflare_interstitial?(html)
        markers_in?(html, INTERSTITIAL_MARKERS)
      end

      def self.markers_in?(text, markers)
        text.present? && markers.any? { |marker| text.include?(marker) }
      end
      private_class_method :markers_in?

      def cloudflare_challenge?
        self.class.cloudflare_challenge?(body)
      end

      # A proxy is "working" if it reached the origin: any 2xx/3xx, or a 403 that is
      # actually a Cloudflare challenge page (the CF source clears it at scrape time via
      # ImpersonateHttp's Chrome TLS). A plain 403 (e.g. a 1020 IP block) is rejected.
      def alive_or_cf_challenge?
        return false unless status
        return true if status.between?(200, 399)

        status == 403 && cloudflare_challenge?
      end
    end
  end
end
