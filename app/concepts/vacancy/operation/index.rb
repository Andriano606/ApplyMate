# frozen_string_literal: true

class Vacancy::Operation::Index < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    authorize! Vacancy.new, :index?

    params = normalize_include_params(params)
    params = normalize_exclude_params(params)

    if params.dig(:vacancy_search, :clear_filter) == '1'
      params[:include_tags]    = nil
      params[:include_ops]     = nil
      params[:exclude_tags]    = nil
      params[:saved_filter_id] = nil
    end

    saved_filter = resolve_saved_filter(params, current_user)
    remember_default_filter(saved_filter, current_user)

    result = run_operation Vacancy::Operation::Search, { params:, current_user: }
    vacancies = result.model
    SavedFilter::RecordView.call(saved_filter:, vacancies:,
                                 include_tags: params[:include_tags],
                                 include_ops:  params[:include_ops],
                                 exclude_tags: params[:exclude_tags])
    applies_by_vacancy = if current_user
      current_user.applies.where(vacancy_id: vacancies.map(&:id)).index_by(&:vacancy_id)
    else
      {}
    end

    self.model = ApplyMate::Operation::Struct.new(
      vacancies:,
      applies_by_vacancy:,
      include_tags: params[:include_tags],
      include_ops:  params[:include_ops],
      exclude_tags: params[:exclude_tags],
      saved_filter:
    )
  end

  private

  # The pill link and the search form both carry saved_filter_id, so the bar
  # knows which preset is being edited across turbo updates.
  def resolve_saved_filter(params, current_user)
    return if params[:saved_filter_id].blank? || current_user.nil?

    current_user.saved_filters.find_by_hashid(params[:saved_filter_id])
  end

  def remember_default_filter(saved_filter, current_user)
    return if saved_filter.nil? || current_user.default_saved_filter_id == saved_filter.id

    current_user.update!(default_saved_filter: saved_filter)
  end

  def normalize_include_params(params)
    return params if params.fetch(:include_ops, {}).is_a?(Array)

    ops = params.fetch(:include_ops, {})
    ops = ops.to_unsafe_h if ops.respond_to?(:to_unsafe_h)
    params[:include_ops] = ops.sort_by { |index, _op| index.to_i }
                              .map { |_index, op| normalize_op(op) }
    if params[:new_include_tag].present?
      params[:include_tags] = [ *params[:include_tags], params[:new_include_tag] ].compact_blank
      params[:include_ops] = [ *params[:include_ops], 'or' ]
    end

    delete_tag_index  = params.fetch(:include_delete_tag, {}).values.map(&:to_b).find_index(&:present?)
    if delete_tag_index
      if delete_tag_index == 0
        params[:include_ops].delete_at(delete_tag_index)
      elsif delete_tag_index >= params[:include_tags].count
        params[:include_ops].delete_at(delete_tag_index - 1)
      else
        left  = params[:include_ops][delete_tag_index-1]
        right = params[:include_ops][delete_tag_index]

        if left == 'g_or' || right == 'g_or'
          # drop the op tying the deleted pill into its group, keep the outer op
          params[:include_ops].delete_at(left == 'g_or' ? delete_tag_index - 1 : delete_tag_index)
        elsif left == 'and'
          params[:include_ops].delete_at(delete_tag_index-1)
        elsif right == 'and'
          params[:include_ops].delete_at(delete_tag_index)
        else
          params[:include_ops].delete_at(delete_tag_index-1)
        end
      end

      params[:include_tags].delete_at(delete_tag_index) unless params[:include_tags].nil?
    end

    params
  end

  # New toggles submit 'and'/'or'/'g_or' directly; legacy checkbox params were boolean-ish
  def normalize_op(op)
    return op if Vacancy::SearchQuery::OPS.include?(op)

    op.to_b ? 'and' : 'or'
  end

  def normalize_exclude_params(params)
    if params[:new_exclude_tag].present?
      params[:exclude_tags] = [ *params[:exclude_tags], params[:new_exclude_tag] ].compact_blank
      params[:new_exclude_tag] = nil
    end

    delete_tag_index  = params.fetch(:exclude_delete_tag, {}).values.map(&:to_b).find_index(&:present?)
    if delete_tag_index && !params[:exclude_tags].nil?
      params[:exclude_tags].delete_at(delete_tag_index)
    end

    params
  end
end
