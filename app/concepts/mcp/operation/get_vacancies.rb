# frozen_string_literal: true

# MCP `get_vacancies`: full records for up to MAX_IDS hashids, in the order
# asked. Unknown ids (deleted by a sync, or mistyped) are reported, not raised.
class Mcp::Operation::GetVacancies < ApplyMate::Operation::Base
  MAX_IDS = 20

  def perform!(params:, current_user:, **)
    authorize! Vacancy.new, :show?

    ids       = Array(params[:ids]).map(&:to_s).compact_blank.uniq.first(MAX_IDS)
    by_hashid = Vacancy.includes(:source)
                       .where(id: ids.filter_map { |id| Vacancy.decode_id(id) })
                       .index_by(&:to_param)
    vacancies = ids.filter_map { |id| by_hashid[id] }

    self.model = ApplyMate::Operation::Struct.new(vacancies:, missing_ids: ids - by_hashid.keys)
  end
end
