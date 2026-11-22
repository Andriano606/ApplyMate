# frozen_string_literal: true

# A titled card of the vacancy page (the description). id is the section's in-page anchor.
class Vacancy::Component::Section < ApplyMate::Component::Base
  def initialize(id:, title:, icon:)
    @id        = id
    @title     = title
    @icon_name = icon
  end

  private

  def title_id
    "#{@id}-title"
  end
end
