# frozen_string_literal: true

class SavedFilter::Component::NewModal < ApplyMate::Component::Base
  def initialize(saved_filter:, **)
    @saved_filter = saved_filter
  end
end
