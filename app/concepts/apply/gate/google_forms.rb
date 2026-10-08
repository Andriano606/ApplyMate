# frozen_string_literal: true

# Google Forms are not submitted by the engine (design §18 item 4: they sit behind a Google sign-in): any hop or
# current URL (an embedded form's frame included) on forms.gle or docs.google.com/forms ->
# Halt(:manual_apply_required, detail: :google_forms), the "apply yourself" needs_human state. Runs before
# SignInWall, which would otherwise call the accounts.google.com redirect a login wall.
class Apply::Gate::GoogleForms < Apply::Gate::Base
  SHORT_HOST = 'forms.gle'
  DOCS_HOST = 'docs.google.com'
  DOCS_PATH = %r{\A/forms(/|\z)}

  def self.events
    %i[http_resolved after_goto]
  end

  def call(_ctx, evidence:, **)
    halt!(:manual_apply_required, detail: :google_forms) if (evidence.hops + evidence.current_urls).any? { |url| form?(url) }
  end

  private

  def form?(url)
    uri = URI.parse(url.to_s)
    host = uri.host&.downcase
    host == SHORT_HOST || (host == DOCS_HOST && DOCS_PATH.match?(uri.path.to_s))
  rescue URI::InvalidURIError
    false
  end
end
