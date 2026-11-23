# frozen_string_literal: true

# The home page: the vacancy search, with a short explainer banner for guests
# above it. The banner stays outside the #vacancy-search frame, so search
# updates (served by /vacancies) never touch or duplicate it.
class Home::Component::Index < ApplyMate::Component::Base
  def initialize(guest_source_names: nil, **vacancy_index)
    @guest_source_names = guest_source_names
    @vacancy_index = vacancy_index
  end

  def call
    safe_join([
      (render Home::Component::GuestBanner.new(source_names: @guest_source_names) if @guest_source_names),
      render(Vacancy::Component::Index.new(**@vacancy_index))
    ].compact)
  end
end
