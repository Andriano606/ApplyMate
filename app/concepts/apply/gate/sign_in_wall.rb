# frozen_string_literal: true

# The form needs an account (design §10.4): the page the run is on is a sign-in host (OAUTH_HOSTS, "host/path"
# prefixes), or a rendered page shows a visible password field (probe/snapshot.js password_fields) ->
# Halt(:login_required). The engine never signs in anywhere.
class Apply::Gate::SignInWall < Apply::Gate::Base
  OAUTH_HOSTS = %w[accounts.google.com login.microsoftonline.com linkedin.com/oauth linkedin.com/uas/login
                   github.com/login].freeze

  def self.events
    %i[http_resolved after_goto after_action]
  end

  # "host/path" of `url` when it is on a sign-in host (OAUTH_HOSTS prefix), else nil. The one sign-in host rule: this
  # gate and Apply::Operation::Recipe::Interpret (a tab a click opened) call it.
  def self.oauth_location(url)
    location = host_path(url)
    location if location && OAUTH_HOSTS.any? { |prefix| location.start_with?(prefix) }
  end

  def call(_ctx, evidence:, snapshot: nil, **)
    location = self.class.oauth_location(main_url(evidence))
    halt!(:login_required, detail: location) if location
    halt!(:login_required, detail: 'password field') if snapshot && password_field?(snapshot)
  end

  private

  def password_field?(snapshot)
    snapshot.frames.sum { |frame| frame['password_fields'].to_i }.positive?
  end
end
