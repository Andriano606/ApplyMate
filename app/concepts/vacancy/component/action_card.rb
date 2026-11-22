# frozen_string_literal: true

# Sidebar of the vacancy page (sticky on lg+, right after the summary on phones): the link to the original
# listing on the source platform. Rendered only for vacancies that have one.
class Vacancy::Component::ActionCard < ApplyMate::Component::Base
  CARD_CLASSES = 'rounded-xl border border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-800'

  def initialize(vacancy:)
    @vacancy = vacancy
  end
end
