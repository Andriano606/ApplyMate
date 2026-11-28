# frozen_string_literal: true

class Admin::ProxyMateSetting::Operation::Update < ApplyMate::Operation::Base
  def perform!(params:, **)
    authorize! ::ProxyMateSetting.current, :update? # before `instance`, which may insert the row

    self.model = ::ProxyMateSetting.instance
    form_object = Admin::ProxyMateSetting::FormObject::Update.new(params[:proxy_mate_setting])
    parse_validate_sync(form_object, model)
    model.save!
    notice(I18n.t('admin.proxy_mate_setting.update.success'))
  end
end
