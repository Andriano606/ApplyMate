# frozen_string_literal: true

# Which gates a platform runs, in order (design §10.4): DEFAULT plus the platform's `extra_gates` minus its
# `skipped_gates`, constantized once per platform class. Order matters: GoogleForms runs before SignInWall (a Google
# Form redirects to accounts.google.com, and §18 wants "apply yourself", not "login required"), CookieConsent before
# VisibleCaptcha. Run them with Apply::Operation::Engine::RunGates.
class Apply::Gate::Registry
  DEFAULT = %w[
    Apply::Gate::PrivateAddress Apply::Gate::GoogleForms Apply::Gate::ExternalMessenger Apply::Gate::SignInWall
    Apply::Gate::DataDome Apply::Gate::CookieConsent Apply::Gate::VisibleCaptcha
  ].freeze

  class << self
    def for(platform_class)
      cache.compute_if_absent(platform_class) do
        (DEFAULT + platform_class.extra_gates - platform_class.skipped_gates).map(&:constantize).freeze
      end
    end

    private

    def cache
      @cache ||= Concurrent::Map.new
    end
  end
end
