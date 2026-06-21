# frozen_string_literal: true

class Admin::Proxy::Serializer::Index < ApplyMate::Serializer::Base
  def call
    { data: @model.map { |stat| serialize(stat) }, pagination: }
  end

  private

  def serialize(stat)
    proxy = stat.proxy
    {
      id: proxy.to_param,
      source: stat.source.name,
      protocol: proxy.protocol,
      host: proxy.host,
      port: proxy.port,
      url: proxy.url,
      success_count: stat.success_count,
      fail_count: stat.fail_count,
      reliability: stat.reliability,
      failed_at: stat.failed_at,
      created_at: stat.created_at,
      updated_at: stat.updated_at
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
