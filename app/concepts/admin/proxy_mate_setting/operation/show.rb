# frozen_string_literal: true

# Admin page for the ProxyMate connection: the saved setting plus a live connection check
# (`sites` with the current config). A failing ProxyMate never fails the page — the error is
# shown in the status block instead. The client bounds every request with timeouts.
class Admin::ProxyMateSetting::Operation::Show < ApplyMate::Operation::Base
  def perform!(**)
    setting = ::ProxyMateSetting.current
    authorize! setting, :show?

    self.model = ApplyMate::Operation::Struct.new(proxy_mate_setting: setting, status: connection_status)
  end

  private

  def connection_status
    ApplyMate::Operation::Struct.new(sites: ApplyMate::Client::ProxyMate.new.sites, error: nil)
  rescue ApplyMate::Client::ProxyMate::ConfigurationError
    failed_status(I18n.t('admin.proxy_mate_setting.status.not_configured'))
  rescue ApplyMate::Client::ProxyMate::ResponseError => e
    failed_status(response_error_message(e))
  rescue ApplyMate::Client::ProxyMate::Error => e
    failed_status(I18n.t('admin.proxy_mate_setting.status.unreachable', detail: e.message))
  end

  def response_error_message(error)
    if [ 401, 403 ].include?(error.http_status)
      I18n.t('admin.proxy_mate_setting.status.unauthorized')
    else
      I18n.t('admin.proxy_mate_setting.status.rejected', detail: error.message)
    end
  end

  def failed_status(message)
    ApplyMate::Operation::Struct.new(sites: [], error: message)
  end
end
