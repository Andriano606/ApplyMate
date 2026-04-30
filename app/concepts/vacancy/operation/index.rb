# frozen_string_literal: true

class Vacancy::Operation::Index < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    authorize! Vacancy.new, :index?

    params = normalize_include_params(params)
    params = normalize_exclude_params(params)

    if params.dig(:vacancy_search, :save_as_default) == '1' && current_user
      current_user.update!(include_tags: params[:include_tags],
                           include_ops: params[:include_ops],
                           exclude_tags: params[:exclude_tags])
    elsif params.dig(:vacancy_search, :load_default) == '1' && current_user
      params[:include_tags] = current_user.include_tags
      params[:include_ops]  = current_user.include_ops
      params[:exclude_tags] = current_user.exclude_tags
    elsif params.dig(:vacancy_search, :clear_filter) == '1'
      params[:include_tags] = nil
      params[:include_ops]  = nil
      params[:exclude_tags] = nil
    end

    result = run_operation Vacancy::Operation::Search, { params:, current_user: }
    vacancies = result.model
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
      exclude_tags: params[:exclude_tags]
    )
  end

  private

  def normalize_include_params(params)
    params[:include_ops] =  params.fetch(:include_ops, {}).values.map { |ops| ops.to_b ? 'and' : 'or' }
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
        if params[:include_ops][delete_tag_index-1] == 'and'
          params[:include_ops].delete_at(delete_tag_index-1)
        elsif params[:include_ops][delete_tag_index] == 'and'
          params[:include_ops].delete_at(delete_tag_index)
        else
          params[:include_ops].delete_at(delete_tag_index-1)
        end
      end

      params[:include_tags].delete_at(delete_tag_index)
    end

    params
  end

  def normalize_exclude_params(params)
    if params[:new_exclude_tag].present?
      params[:exclude_tags] = [ *params[:exclude_tags], params[:new_exclude_tag] ].compact_blank
    end

    delete_tag_index  = params.fetch(:exclude_delete_tag, {}).values.map(&:to_b).find_index(&:present?)
    if delete_tag_index
      params[:exclude_tags].delete_at(delete_tag_index)
    end

    params
  end
end
