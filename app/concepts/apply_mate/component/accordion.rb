# frozen_string_literal: true

class ApplyMate::Component::Accordion < ApplyMate::Component::Base
  def initialize(title:, open: false)
    @title = title
    @open = open
  end
end
