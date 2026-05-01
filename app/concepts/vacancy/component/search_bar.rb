# frozen_string_literal: true

class Vacancy::Component::SearchBar < ApplyMate::Component::Base
  def initialize(include_tags: nil, include_ops: nil, exclude_tags: nil, count: nil)
    @include_tags = include_tags
    @include_ops = include_ops
    @exclude_tags = exclude_tags
    @count = count
  end

  private

  def show_clear_filter?
    @show_clear_filter ||= !@include_tags.blank? ||
      !@exclude_tags.blank? ||
      !@include_ops.blank?
  end

  def show_load_default?
    @show_load_default ||= current_user && (normalize_prop(current_user.include_tags) != normalize_prop(@include_tags) ||
      normalize_prop(current_user.include_ops) != normalize_prop(@include_ops) ||
      normalize_prop(current_user.exclude_tags) != normalize_prop(@exclude_tags)) &&
                           (!current_user.include_tags.blank? || !current_user.exclude_tags.blank?)
  end

  def show_save_default?
    @show_save_default ||= current_user && (normalize_prop(current_user.include_tags) != normalize_prop(@include_tags) ||
      normalize_prop(current_user.include_ops) != normalize_prop(@include_ops) ||
      normalize_prop(current_user.exclude_tags) != normalize_prop(@exclude_tags))
  end

  def normalize_prop(prop)
    prop || []
  end

  def search_pill_input(f, tags:, ops:, name_prefix:)
    # name_prefix: наприклад, :include (для tags та ops)
    tags_field = "#{name_prefix}_tags"
    new_tag_field = "new_#{name_prefix}_tag"

    content_tag(:div) do
      # 1. Основний контейнер
      concat(content_tag(:div, class: 'flex flex-wrap items-center gap-2 p-2 rounded-xl border-0 ring-1 ring-inset ring-gray-300 dark:ring-gray-700 bg-white dark:bg-gray-800 shadow-sm transition-all min-h-[3rem]') do
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

  # tags = ['ruby', 'react', 'rails']
  # ops  = ['and', 'or']
  # => [['ruby', 'react'], ['rails']]
  def group_tags_by_logic(tags, ops)
    return [] if tags.blank?

    result = [ [ tags.first ] ]

    ops.each_with_index do |op, index|
      next_tag = tags[index + 1]
      break unless next_tag

      if op.to_s.downcase == 'and'
        # Додаємо в останню існуючу групу
        result.last << next_tag
      else
        # Створюємо нову групу для OR
        result << [ next_tag ]
      end
    end

    result
  end

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

    grouped_indexes = group_tag_indexes_by_logic(tags, ops)
    ops_field = "#{name_prefix}_ops"

    @op_counter = 0 # Використовуємо інстанс-змінну або переконуємося, що локальна змінюється коректно

    capture do
      grouped_indexes.each_with_index do |index_group, g_idx|
        if index_group.size > 1
          # Рендеримо контент групи окремо, щоб лічильник оновився гарантовано
          group_html = capture do
            index_group.each_with_index do |tag_idx, t_idx|
              if t_idx > 0
                concat render_logic_link(f, ops_field, @op_counter)
                @op_counter += 1
              end
              concat render Vacancy::Component::SearchBar::Tag.new(form: f, name: delete_field, label: tags[tag_idx], index: tag_idx)
            end
          end

          concat content_tag(:div, group_html, class: 'inline-flex items-center gap-2 p-1 bg-gray-50 dark:bg-gray-800 border border-gray-200 dark:border-gray-700 rounded-full shadow-sm flex-shrink-0')
        else
          tag_idx = index_group.first
          concat render Vacancy::Component::SearchBar::Tag.new(form: f, name: delete_field, label: tags[tag_idx], index: tag_idx)
        end

        # Оператор МІЖ групами
        if g_idx < grouped_indexes.size - 1
          concat render_logic_link(f, ops_field, @op_counter)
          @op_counter += 1
        end
      end
    end
  end

  def group_tag_indexes_by_logic(tags, ops)
    return [] if tags.blank?

    # Починаємо з першого індексу [0]
    result = [ [ 0 ] ]

    ops.each_with_index do |op, index|
      next_tag_index = index + 1
      break unless tags[next_tag_index]

      if op.to_s.downcase == 'and'
        result.last << next_tag_index
      else
        result << [ next_tag_index ]
      end
    end

    result
  end

  def render_logic_link(f, field_name, index)
    current_val = @include_ops[index]
    is_and = (current_val == 'and')

    boolean_link(
      form: f,
      name: field_name.to_sym,
      index: index,
      checked: is_and,
      label: is_and ? I18n.t('vacancy.search.and') : I18n.t('vacancy.search.or'),
      label_class: 'text-[10px] font-bold tracking-widest text-gray-400 hover:text-indigo-500 \
        transition-colors duration-200 select-none px-1',
      data: { action: 'change->turbo-form#update' }
    )
  end

  def link_button_label_class
    'text-sm font-medium text-gray-500 dark:text-gray-400 hover:text-gray-700 \
      dark:hover:text-gray-200 transition-colors duration-200 cursor-pointer'
  end
end
