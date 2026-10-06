# frozen_string_literal: true

# A titled card of the vacancy page (description, applies, CVs, questions). id is the anchor the sidebar
# section nav links to; data: lets a section attach a Stimulus controller (anchor-scroll on lazy frames).
class Vacancy::Component::Section < ApplyMate::Component::Base
  renders_one :header_action

  def initialize(id:, title:, icon:, data: {})
    @id        = id
    @title     = title
    @icon_name = icon
    @data      = data
  end

  private

  def title_id
    "#{@id}-title"
  end
end
