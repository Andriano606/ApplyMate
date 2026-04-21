# frozen_string_literal: true

class Admin::Dashboard::Component::Card < ApplyMate::Component::Base
  def initialize(path:, icon_bg:, title:, description:, turbo: true)
    @path = path
    @icon_bg = icon_bg
    @title = title
    @description = description
    @turbo = turbo
  end

  def link_options
    opts = { class: 'block bg-white dark:bg-gray-800 rounded-xl shadow-md p-6 hover:shadow-lg transition-shadow' }
    opts[:data] = { turbo: false } unless @turbo
    opts
  end

  def icon_container_class
    "w-12 h-12 #{@icon_bg} rounded-lg flex items-center justify-center"
  end
end
