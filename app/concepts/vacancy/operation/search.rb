# frozen_string_literal: true

# Runs the vacancy search built by Vacancy::Operation::BuildSearchQuery (see it
# for the include/exclude tags and ops semantics) and returns a WillPaginate
# collection sorted newest-first.
class Vacancy::Operation::Search < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    authorize! Vacancy.new, :index?

    query = run_operation(Vacancy::Operation::BuildSearchQuery,
                          { include_tags: params[:include_tags],
                            include_ops:  params[:include_ops],
                            exclude_tags: params[:exclude_tags] }).model
    page     = [ params[:page].to_i, 1 ].max
    per_page = WillPaginate.per_page

    raw = Vacancy.search(search_body(query, page, per_page)).response

    total = raw.dig('hits', 'total', 'value').to_i
    ids   = raw['hits']['hits'].map { |h| h['_id'].to_i }
    by_id = Vacancy.where(id: ids).index_by(&:id)

    self.model = WillPaginate::Collection.create(page, per_page, total) do |pager|
      pager.replace(ids.filter_map { |id| by_id[id] })
    end
  end

  private

  def search_body(query, page, per_page)
    {
      query:            query,
      sort:             [ { vacancy_id: { order: 'desc' } } ],
      from:             (page - 1) * per_page,
      size:             per_page,
      track_total_hits: true
    }
  end
end
