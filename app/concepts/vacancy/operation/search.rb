# frozen_string_literal: true

# Runs the vacancy search built by Vacancy::SearchQuery (see it for the
# include/exclude tags and ops semantics) and returns a WillPaginate collection.
class Vacancy::Operation::Search < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    authorize! Vacancy.new, :index?

    query = Vacancy::SearchQuery.new(include_tags: params[:include_tags],
                                     include_ops:  params[:include_ops],
                                     exclude_tags: params[:exclude_tags])
    page     = [ params[:page].to_i, 1 ].max
    per_page = WillPaginate.per_page

    raw = Vacancy.search(query.search_body(page:, per_page:)).response

    total = raw.dig('hits', 'total', 'value').to_i
    ids   = raw['hits']['hits'].map { |h| h['_id'].to_i }
    by_id = Vacancy.where(id: ids).index_by(&:id)

    self.model = WillPaginate::Collection.create(page, per_page, total) do |pager|
      pager.replace(ids.filter_map { |id| by_id[id] })
    end
  end
end
