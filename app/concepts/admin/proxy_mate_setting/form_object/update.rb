# frozen_string_literal: true

# Built WITHOUT the model, so only the submitted fields are dirty: a blank URL or API key
# (the form never re-sends the stored key) leaves the saved value untouched.
class Admin::ProxyMateSetting::FormObject::Update < ApplyMate::FormObject::Base
  URL_FORMAT = %r{\Ahttps?://\S+\z}i

  properties :url, :api_key

  validates :url, format: { with: URL_FORMAT, message: ->(*) { I18n.t('admin.proxy_mate_setting.errors.invalid_url') } },
                  allow_blank: true
end
