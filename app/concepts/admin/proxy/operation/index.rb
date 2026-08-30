# frozen_string_literal: true

class Admin::Proxy::Operation::Index < ApplyMate::Operation::Base
  def perform!(params:, **)
    authorize! Proxy, :index?
    # Per-(proxy, source) stats, most reliable first. Only tested pairs have a row;
    # untested proxies are reflected in the per-source counts (component), not listed.
    self.model = ProxySourceStat.includes(:proxy, :source)
                                .by_reliability
                                .paginate(page: params[:page])
  end
end
