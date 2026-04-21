# frozen_string_literal: true

class Session::Operation::OauthCallback < ApplyMate::Operation::Base
  def perform!(params:, current_user:)
    skip_authorize

    params = params[:auth]['info'].merge({ provider: params[:auth]['provider'], uid: params[:auth]['uid'] })
    form_object = Session::FormObject::OauthCallback.new(params)
    self.model = User.find_or_initialize_by(provider: form_object.provider, uid: form_object.uid)

    avatar_changed = model.avatar_url != form_object.avatar_url

    parse_validate_sync(form_object)
    model.save!

    sync_avatar! if avatar_changed || !model.avatar.attached?
  end

  private

  def sync_avatar!
    model.avatar.purge if model.avatar.attached?
    model.download_avatar!
  end
end
