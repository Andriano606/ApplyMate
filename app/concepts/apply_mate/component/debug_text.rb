# frozen_string_literal: true

class ApplyMate::Component::DebugText < ApplyMate::Component::Base
  available_for :dev

  def initialize(text:)
    @text = text
  end
end
