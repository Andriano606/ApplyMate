# frozen_string_literal: true

class SourceProfile::Component::SessionIdForm < ApplyMate::Component::Base
  def initialize(form:, source_profile:)
    @form = form
    @source_profile = source_profile
  end
end
