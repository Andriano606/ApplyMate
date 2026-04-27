# frozen_string_literal: true

class SourceProfile::Component::SelectOption < ApplyMate::Component::Base
  def initialize(source_profile:)
    @source_profile = source_profile
  end

  def call
    tag.option("#{@source_profile.source.name} (#{@source_profile.name})", value: @source_profile.id)
  end
end
