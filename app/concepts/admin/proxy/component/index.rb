# frozen_string_literal: true

class Admin::Proxy::Component::Index < ApplyMate::Component::Base
  available_for :admin

  # `proxies` is the paginated collection of ProxySourceStat rows (per proxy+source).
  def initialize(proxies:, **)
    @stats = proxies
  end

  # Per-source buckets. A proxy that works for one site is often blocked on another,
  # so counts are per source. "untested" for a source = proxies with no stat row yet.
  def source_stats
    @source_stats ||= begin
      total   = Proxy.count
      grouped = ProxySourceStat.group(:source_id).pluck(
        :source_id,
        Arel.sql('count(*) FILTER (WHERE success_count > 0 AND reliability >= 0.5)'),
        Arel.sql('count(*) FILTER (WHERE success_count > 0 AND reliability <  0.5)'),
        Arel.sql('count(*) FILTER (WHERE success_count = 0 AND fail_count  >  0)'),
        Arel.sql('count(*)')
      ).index_by(&:first)

      Source.order(:name).map do |source|
        _id, working, flaky, dead, tested = grouped[source.id] || [ source.id, 0, 0, 0, 0 ]
        {
          name: source.name,
          buckets: [
            { color: :green,  dot: 'bg-green-500',  label: I18n.t('admin.proxy.index.stats.working'),  count: working.to_i },
            { color: :yellow, dot: 'bg-yellow-500', label: I18n.t('admin.proxy.index.stats.flaky'),    count: flaky.to_i },
            { color: :red,    dot: 'bg-red-500',    label: I18n.t('admin.proxy.index.stats.dead'),     count: dead.to_i },
            { color: :gray,   dot: 'bg-gray-400',   label: I18n.t('admin.proxy.index.stats.untested'), count: total - tested.to_i }
          ]
        }
      end
    end
  end

  BADGE_BASE = 'inline-flex items-center gap-1 px-2.5 py-1 rounded-full text-xs font-semibold border'
  BADGE_COLORS = {
    green:  'bg-green-100 text-green-800 border-green-200 dark:bg-green-900 dark:text-green-300 dark:border-green-700',
    yellow: 'bg-yellow-100 text-yellow-800 border-yellow-200 dark:bg-yellow-900 dark:text-yellow-300 dark:border-yellow-700',
    red:    'bg-red-100 text-red-800 border-red-200 dark:bg-red-900 dark:text-red-300 dark:border-red-700',
    gray:   'bg-gray-100 text-gray-700 border-gray-200 dark:bg-gray-800 dark:text-gray-300 dark:border-gray-700'
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
