# frozen_string_literal: true

# Sidebar of the vacancy page (sticky on lg+, right after the summary on phones): live apply state,
# the original listing, AI tools and the in-page section nav. Guests get a sign-in call to action.
class Vacancy::Component::ActionCard < ApplyMate::Component::Base
  CARD_CLASSES = 'rounded-xl border border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-800'

  def initialize(vacancy:)
    @vacancy = vacancy
  end

  private

  # [anchor, label, icon]; the workspace sections exist for signed-in users only.
  def nav_items
    items = [ [ 'vacancy-description', I18n.t('vacancy.show.nav.description'), :info_circle ] ]
    return items unless signed_in?

    items + [
      [ 'vacancy-applies', I18n.t('vacancy.show.nav.applies'), :send ],
      [ 'vacancy-cvs', I18n.t('vacancy.show.nav.cvs'), :document_text ],
      [ 'vacancy-questions', I18n.t('vacancy.show.nav.questions'), :chat_bubble ]
    ]
  end
end
