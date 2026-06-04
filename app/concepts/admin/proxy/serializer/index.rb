# frozen_string_literal: true

class Admin::Proxy::Serializer::Index < ApplyMate::Serializer::Base
  def call
    { data: @model.map { |proxy| serialize(proxy) }, pagination: }
  end

  private

  def serialize(proxy)
    {
      id: proxy.to_param,
      protocol: proxy.protocol,
      host: proxy.host,
      port: proxy.port,
      url: proxy.url,
      success_count: proxy.success_count,
      fail_count: proxy.fail_count,
      failed_at: proxy.failed_at,
      created_at: proxy.created_at,
      updated_at: proxy.updated_at
    }
  end

  def pagination
    {
      current_page: @model.current_page,
      total_pages: @model.total_pages,
      total_entries: @model.total_entries,
      next_page: @model.next_page
    }
  end
end
