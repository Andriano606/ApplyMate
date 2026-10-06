# frozen_string_literal: true

# Centered "nothing here yet" block: icon, title, hint and an optional call-to-action passed as the block.
class ApplyMate::Component::EmptyState < ApplyMate::Component::Base
  def initialize(icon:, title:, hint: nil)
    @icon_name = icon
    @title     = title
    @hint      = hint
  end
end
