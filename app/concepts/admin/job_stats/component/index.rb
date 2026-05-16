# frozen_string_literal: true

class Admin::JobStats::Component::Index < ApplyMate::Component::Base
  available_for :admin

  DAYS = 30

  COLORS = %w[#6366f1 #10b981 #f59e0b #ef4444 #8b5cf6 #06b6d4 #f97316 #ec4899 #84cc16 #14b8a6].freeze

  CHART_W = 860
  CHART_H = 300
  PAD_L   = 58
  PAD_R   = 20
  PAD_T   = 16
  PAD_B   = 50

  def initialize(job_stats:, **)
    @dates  = (DAYS.days.ago.to_date..Date.today).to_a
    @series = build_series(job_stats)
  end

  def header_opts
    {
      title: I18n.t('admin.job_stats.index.title'),
      back_link: helpers.admin_root_path,
      back_text: I18n.t('admin.common.back_to_dashboard')
    }
  end

  def legend_items
    @series.each_with_index.map do |(class_name, _), idx|
      { label: short_name(class_name), color: COLORS[idx % COLORS.size] }
    end
  end

  def chart_svg
    plot_w = CHART_W - PAD_L - PAD_R
    plot_h = CHART_H - PAD_T  - PAD_B
    n      = @dates.size
    max    = @series.values.flat_map(&:values).max.to_f
    max    = 1.0 if max.zero?

    parts = []
    parts << %(<svg viewBox="0 0 #{CHART_W} #{CHART_H}" xmlns="http://www.w3.org/2000/svg" class="w-full h-auto">)

    # Gridlines + Y-axis labels (5 ticks)
    5.times do |i|
      ratio = i / 4.0
      y     = (PAD_T + plot_h * (1.0 - ratio)).round(2)
      val   = format_seconds(max * ratio)
      parts << %(<line x1="#{PAD_L}" y1="#{y}" x2="#{CHART_W - PAD_R}" y2="#{y}" stroke="#e5e7eb" stroke-width="1"/>)
      parts << %(<text x="#{PAD_L - 5}" y="#{(y + 4).round(2)}" text-anchor="end" font-size="10" fill="#6b7280">#{val}</text>)
    end

    # Y-axis label
    mid_y = (PAD_T + plot_h / 2.0).round(2)
    parts << %(<text x="11" y="#{mid_y}" text-anchor="middle" font-size="10" fill="#9ca3af" transform="rotate(-90, 11, #{mid_y})">#{I18n.t('admin.job_stats.index.y_axis_label')}</text>)

    # X-axis labels (every 3rd day)
    @dates.each_with_index do |d, i|
      next unless (i % 3).zero? || i == n - 1
      x = x_pos(i, n, plot_w)
      parts << %(<text x="#{x}" y="#{PAD_T + plot_h + 18}" text-anchor="middle" font-size="10" fill="#9ca3af">#{d.strftime('%-d.%-m')}</text>)
    end

    # One polyline + dots per job class
    @series.each_with_index do |(class_name, day_map), idx|
      color  = COLORS[idx % COLORS.size]
      points = @dates.each_with_index.filter_map do |d, i|
        val = day_map[d]
        next unless val
        "#{x_pos(i, n, plot_w)},#{y_pos(val, max, plot_h)}"
      end

      next if points.empty?

      parts << %(<polyline points="#{points.join(' ')}" fill="none" stroke="#{color}" stroke-width="2" stroke-linejoin="round" stroke-linecap="round"/>)

      @dates.each_with_index do |d, i|
        val = day_map[d]
        next unless val
        cx = x_pos(i, n, plot_w)
        cy = y_pos(val, max, plot_h)
        parts << %(<circle cx="#{cx}" cy="#{cy}" r="3.5" fill="#{color}" stroke="white" stroke-width="1.5">)
        parts << %(  <title>#{short_name(class_name)} · #{d.strftime('%d.%m.%Y')}: #{format_seconds(val)}</title>)
        parts << %(</circle>)
      end
    end

    # Axes
    ax_y = (PAD_T + plot_h).round(2)
    parts << %(<line x1="#{PAD_L}" y1="#{PAD_T}" x2="#{PAD_L}" y2="#{ax_y}" stroke="#d1d5db" stroke-width="1"/>)
    parts << %(<line x1="#{PAD_L}" y1="#{ax_y}" x2="#{CHART_W - PAD_R}" y2="#{ax_y}" stroke="#d1d5db" stroke-width="1"/>)

    parts << %(</svg>)
    parts.join("\n").html_safe
  end

  private

  def build_series(stats)
    by_class = stats.group_by(&:class_name)
    by_class.transform_values do |rows|
      rows.each_with_object({}) { |r, h| h[r.day.to_date] = r.avg_seconds.to_f.round(2) }
    end
  end

  def x_pos(i, n, plot_w)
    denominator = [ n - 1, 1 ].max
    (PAD_L + i.to_f / denominator * plot_w).round(2)
  end

  def y_pos(val, max, plot_h)
    (PAD_T + plot_h - (val / max) * plot_h).round(2)
  end

  def short_name(class_name)
    class_name.split('::').last(2).join('::')
  end

  def format_seconds(val)
    return '0' if val.zero?
    val >= 60 ? "#{(val / 60).round(1)}хв" : "#{val.round(1)}с"
  end
end
