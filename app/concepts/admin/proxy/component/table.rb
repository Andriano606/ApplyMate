class Admin::Proxy::Component::Table < ApplyMate::Component::Base
  available_for :admin

  # `proxies` is a collection of ProxySourceStat rows (per proxy + source).
  def initialize(proxies:, **)
    @stats = proxies
  end

  def call
    table = ApplyMate::Component::Table.new(rows: @stats, empty_message: I18n.t('admin.proxy.index.empty'))

    table.add_column(header: I18n.t('admin.proxy.index.table.url')) do |stat|
      helpers.content_tag(:span, stat.proxy.url, class: 'font-mono text-sm')
    end

    table.add_column(header: I18n.t('admin.proxy.index.table.source')) do |stat|
      helpers.content_tag(:span, stat.source.name)
    end

    table.add_column(header: I18n.t('admin.proxy.index.table.success_count')) do |stat|
      css = stat.success_count.to_i > 0 ? 'text-green-600 font-medium' : 'text-gray-400'
      helpers.content_tag(:span, stat.success_count.to_i, class: css)
    end

    table.add_column(header: I18n.t('admin.proxy.index.table.fail_count')) do |stat|
      css = case stat.fail_count
      when 0     then 'text-green-600'
      when 1..9  then 'text-yellow-600'
      else            'text-red-600 font-medium'
      end
      helpers.content_tag(:span, stat.fail_count, class: css)
    end

    table.add_column(header: I18n.t('admin.proxy.index.table.ratio')) do |stat|
      total = stat.success_count + stat.fail_count
      if total.zero?
        helpers.content_tag(:span, '—', class: 'text-gray-400')
      else
        pct = (stat.success_count.to_f / total * 100).round
        css = pct >= 75 ? 'text-green-600 font-medium' : (pct >= 40 ? 'text-yellow-600' : 'text-red-600 font-medium')
        helpers.content_tag(:span, "#{pct}%", class: css)
      end
    end

    table.add_column(header: I18n.t('admin.proxy.index.table.failed_at')) do |stat|
      stat.failed_at ? helpers.l(stat.failed_at, format: :short) : '—'
    end

    table.add_column(header: I18n.t('admin.proxy.index.table.actions'), type: :actions) do |stat|
      circle = helpers.content_tag(:span, icon(:eye), class: 'inline-flex items-center justify-center w-8 h-8 rounded-full border border-gray-300 dark:border-gray-600 text-gray-500 dark:text-gray-400 group-hover:border-gray-600 dark:group-hover:border-gray-300 group-hover:text-gray-800 dark:group-hover:text-gray-100 transition-colors')
      helpers.link_to(circle, helpers.admin_proxy_path(stat.proxy), class: 'group', 'data-turbo-stream': true)
    end

    render table
  end
end
