# frozen_string_literal: true

class UserProfile::Component::Index < ApplyMate::Component::Base
  def initialize(user_profiles:, **)
    @user_profiles = user_profiles
  end

  private

  def header_opts
    { title: I18n.t('user_profile.index.title') }
  end
end
