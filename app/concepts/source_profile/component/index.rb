# frozen_string_literal: true

class SourceProfile::Component::Index < ApplyMate::Component::Base
  def initialize(source_profiles:, **)
    @source_profiles = source_profiles
  end

  private

  def header_opts
    { title: I18n.t('source_profile.index.title') }
  end
end
