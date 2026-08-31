# frozen_string_literal: true

class Vacancy::Component::SearchBar < ApplyMate::Component::Base
  def initialize(include_tags: nil, include_ops: nil, exclude_tags: nil, saved_filter: nil, count: nil)
    @include_tags = include_tags
    @include_ops = include_ops
    @exclude_tags = exclude_tags
    @saved_filter = saved_filter
    @count = count
  end

  private

  def show_clear_filter?
    @show_clear_filter ||= !@include_tags.blank? ||
      !@exclude_tags.blank? ||
      !@include_ops.blank?
  end

  def search_pill_input(f, tags:, ops:, name_prefix:)
    # name_prefix: наприклад, :include (для tags та ops)
    tags_field = "#{name_prefix}_tags"
    new_tag_field = "new_#{name_prefix}_tag"

    content_tag(:div) do
      # 1. Основний контейнер
      # Fixed height: pills never wrap; overflow scrolls horizontally instead of growing the bar
      concat(content_tag(:div, class: 'flex flex-nowrap items-center gap-2 px-2 h-14 overflow-x-auto [scrollbar-width:thin] rounded-xl border-0 ring-1 ring-inset ring-gray-300 dark:ring-gray-700 bg-white dark:bg-gray-800 shadow-sm transition-all') do
        # Рендеримо згруповані теги (метод, який ми створили раніше)
        concat render_grouped_tags(f, tags, ops, name_prefix)

        # Текстове поле для нового тегу
        concat text_field_tag(new_tag_field, nil,
                              class: 'flex-1 border-0 bg-transparent text-gray-900 dark:text-white p-1 outline-none text-sm min-w-[200px]',
                              placeholder: I18n.t("vacancy.search.#{name_prefix}_label"),
                              data: { action: 'change->turbo-form#update' }
               )

        # Кнопка Add
        concat button(label: I18n.t('vacancy.search.add'),
                      variant: :secondary,
                      size: :md,
                      tag: :button,
                      class: 'text-indigo-600 hover:text-indigo-800 dark:text-indigo-400 dark:hover:text-indigo-300 font-medium text-sm px-3 py-1 rounded-lg hover:bg-indigo-50 dark:hover:bg-indigo-900/30 transition-colors flex-shrink-0',
                      'data-action': 'click->turbo-form#update')
      end)

      # 2. Приховані поля для передачі масиву тегів у параметри
      tags&.each do |tag|
        concat f.input tags_field.to_sym, as: :hidden,
                       input_html: { name: "#{tags_field}[]", value: tag.to_s },
                       wrapper: false
      end
    end
  end

  AND_GROUP_CLASSES = 'inline-flex items-center gap-2 p-1 bg-gray-50 dark:bg-gray-800 ' \
    'border border-gray-200 dark:border-gray-700 rounded-full shadow-sm flex-shrink-0'
  OR_GROUP_CLASSES = 'inline-flex items-center gap-1 p-1 bg-indigo-50/50 dark:bg-indigo-900/20 ' \
    'border border-indigo-200 dark:border-indigo-800 rounded-full shadow-sm flex-shrink-0'
  PAREN_CLASSES = 'text-sm font-semibold text-indigo-400 dark:text-indigo-500 select-none'

  # Ops between pills: 'g_or' joins the neighbours into an explicit
  # parenthesized OR unit, then 'and' binds units tighter than 'or'
  # (mirrors Vacancy::Operation::Search#build_include).
  def render_grouped_tags(f, tags, ops, name_prefix)
    return if tags.blank?

    delete_field = "#{name_prefix}_delete_tag"

    if ops.blank?
      return capture do
        tags.each_with_index do |tag, index|
          concat render Vacancy::Component::SearchBar::Tag.new(form: f, name: delete_field, label: tag, index: index)
        end
      end
    end

    ops_field = "#{name_prefix}_ops"
    groups = and_groups(or_units(tags, ops), ops)

    capture do
      groups.each_with_index do |units, group_idx|
        concat render_and_group(f, units, tags, ops_field, delete_field)
        # toggle between AND-groups; op index = index of the tag left of the boundary
        concat render_op_toggle(ops_field, groups[group_idx + 1].first.first - 1) if group_idx < groups.size - 1
      end
    end
  end

  # tags: 4 pills, ops: [and, g_or, or] => units of tag indexes: [[0], [1, 2], [3]]
  def or_units(tags, ops)
    units = [ [ 0 ] ]
    (1...tags.size).each do |i|
      ops[i - 1] == 'g_or' ? units.last << i : units << [ i ]
    end
    units
  end

  # units chained by 'and' render inside one visual group: [[0], [1, 2]], [[3]]
  def and_groups(units, ops)
    groups = [ [ units.first ] ]
    units.each_cons(2) do |left, right|
      (ops[left.last] || 'and') == 'and' ? groups.last << right : groups << [ right ]
    end
    groups
  end

  def render_and_group(f, units, tags, ops_field, delete_field)
    html = capture do
      units.each_with_index do |unit, unit_idx|
        concat render_op_toggle(ops_field, unit.first - 1) if unit_idx > 0
        concat render_or_unit(f, unit, tags, ops_field, delete_field)
      end
    end

    units.size > 1 ? content_tag(:div, html, class: AND_GROUP_CLASSES) : html
  end

  def render_or_unit(f, unit, tags, ops_field, delete_field)
    if unit.one?
      return render Vacancy::Component::SearchBar::Tag.new(form: f, name: delete_field,
                                                           label: tags[unit.first], index: unit.first)
    end

    html = capture do
      concat content_tag(:span, '(', class: PAREN_CLASSES)
      unit.each_with_index do |tag_idx, idx_in_unit|
        concat render_op_toggle(ops_field, tag_idx - 1) if idx_in_unit > 0
        concat render Vacancy::Component::SearchBar::Tag.new(form: f, name: delete_field,
                                                             label: tags[tag_idx], index: tag_idx)
      end
      concat content_tag(:span, ')', class: PAREN_CLASSES)
    end

    content_tag(:div, html, class: OR_GROUP_CLASSES)
  end

  def render_op_toggle(ops_field, index)
    render Vacancy::Component::SearchBar::OpToggle.new(name: ops_field, index:, value: @include_ops[index])
  end
end
