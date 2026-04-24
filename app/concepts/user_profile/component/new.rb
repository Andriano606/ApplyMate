# frozen_string_literal: true

class UserProfile::Component::New < ApplyMate::Component::Base
  def initialize(user_profile:, **)
    @user_profile = user_profile
  end

  private

  def header_opts
    {
      title: I18n.t('user_profile.new.title'),
      back_link: helpers.user_profiles_path,
      back_text: I18n.t('user_profile.new.back')
    }
  end
end
