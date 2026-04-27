# frozen_string_literal: true

class SourceProfile::Component::Modal < ApplyMate::Component::Base
  AUTH_METHOD_UI = {
    session_id: { label: 'Session ID', icon_name: :lock_closed }
  }.freeze

  def initialize(source_profile:, **)
    @source_profile = source_profile
  end
end
