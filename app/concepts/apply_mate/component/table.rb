# frozen_string_literal: true

class ApplyMate::Component::Table < ViewComponent::Base
  include WillPaginate::ViewHelpers

  Column = Struct.new(:header, :type, :block, keyword_init: true)

  attr_reader :rows, :columns, :empty_message, :paginate_options

  def initialize(rows:, empty_message: nil, paginate: true, **paginate_options)
    @rows = rows
    @columns = []
    @empty_message = empty_message || I18n.t('components.table.empty')
    @paginate_enabled = paginate
    @paginate_options = paginate_options
  end

  def add_column(header: nil, type: :text, &block)
    @columns << Column.new(header: header, type: type, block: block)
    self
  end

  def render?
    columns.any?
  end

  def paginate?
    @paginate_enabled && rows.respond_to?(:total_pages) && rows.total_pages > 1
  end

  def cell_content(column, row)
    return '' unless column.block

    result = column.block.call(row)
    case result
    when ActiveSupport::SafeBuffer, String
      result
    when Integer, Float
      result.to_s
    else
      result.to_s.html_safe
    end
  end

  def cell_class(column)
    case column.type
    when :button, :actions
      'px-4 py-3 text-right'
    else
      'px-4 py-3 text-gray-800 dark:text-gray-200'
    end
  end

  def header_class(column)
    case column.type
    when :button, :actions
      'px-4 py-3 text-right text-sm font-semibold text-gray-600 dark:text-gray-400'
    else
      'px-4 py-3 text-left text-sm font-semibold text-gray-600 dark:text-gray-400'
    end
  end

  def row_id(row)
    row.respond_to?(:id) ? row.id : nil
  end
end
