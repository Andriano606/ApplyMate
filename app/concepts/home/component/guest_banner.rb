# frozen_string_literal: true

# For visitors who are not signed in: what ApplyMate is, in plain words, and
# one button to sign in with Google (which also creates the account) to get
# Claude connected over MCP.
class Home::Component::GuestBanner < ApplyMate::Component::Base
  POINTS = [
    [ :magnifying_glass, 'search' ],
    [ :eye_slash, 'hide' ],
    [ :sparkles, 'claude' ]
  ].freeze

  def initialize(source_names:)
    @source_names = source_names
  end

  private

  def sources
    @source_names.presence&.to_sentence(two_words_connector: ' і ', last_word_connector: ' і ') ||
      I18n.t('home.guest_banner.sources_fallback')
  end
end
