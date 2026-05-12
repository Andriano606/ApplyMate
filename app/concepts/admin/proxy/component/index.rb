# frozen_string_literal: true

class Admin::Proxy::Component::Index < ApplyMate::Component::Base
  available_for :admin

  def initialize(proxies:, **)
    @proxies = proxies
  end

  def counts
    @counts ||= begin
      raw = Proxy.group(
        Arel.sql("CASE WHEN fail_count = 0 THEN 'green' WHEN fail_count < 10 THEN 'yellow' ELSE 'red' END")
      ).count
      { green: raw['green'].to_i, yellow: raw['yellow'].to_i, red: raw['red'].to_i }
    end
  end

  BADGE_BASE = 'inline-flex items-center gap-1 px-2.5 py-1 rounded-full text-xs font-semibold border'
  BADGE_COLORS = {
    green:  'bg-green-100 text-green-800 border-green-200 dark:bg-green-900 dark:text-green-300 dark:border-green-700',
    yellow: 'bg-yellow-100 text-yellow-800 border-yellow-200 dark:bg-yellow-900 dark:text-yellow-300 dark:border-yellow-700',
    red:    'bg-red-100 text-red-800 border-red-200 dark:bg-red-900 dark:text-red-300 dark:border-red-700'
  }.freeze

  def badge_css(color) = "#{BADGE_BASE} #{BADGE_COLORS[color]}"

  def header_opts
    {
      title: I18n.t('admin.proxy.index.title'),
      back_link: helpers.admin_root_path,
      back_text: I18n.t('admin.common.back_to_dashboard')
    }
  end
end
