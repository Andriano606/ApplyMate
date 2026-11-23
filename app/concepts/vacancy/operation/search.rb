# frozen_string_literal: true

# Runs the vacancy search built by Vacancy::Operation::BuildSearchQuery (see it
# for the include/exclude tags and ops semantics) and returns a WillPaginate
# collection, newest-first by default.
#
# The keyword options are not taken from request params on purpose — only
# trusted callers (the MCP search tool) set them:
#   per_page       — page size, clamped to 1..MAX_PER_PAGE
#   sort           — 'newest' (default) or 'relevance' (ES score, newest on ties)
#   must_tags / source_ids — passed through to BuildSearchQuery
#   exclude_hidden — drop the vacancies current_user has hidden
class Vacancy::Operation::Search < ApplyMate::Operation::Base
  MAX_PER_PAGE = 100
  SORTS = {
    'newest'    => [ { vacancy_id: { order: 'desc' } } ],
    'relevance' => [ '_score', { vacancy_id: { order: 'desc' } } ]
  }.freeze

  # Deepest page Elasticsearch can serve at this page size (from + size must stay
  # inside the index's max_result_window). The collection keeps the real total —
  # the web shows it — so paginating callers must stop here themselves.
  def self.last_reachable_page(per_page)
    Vacancy::MAX_RESULT_WINDOW / per_page
  end

  def perform!(params:, current_user:, per_page: WillPaginate.per_page, sort: 'newest',
               must_tags: nil, source_ids: nil, exclude_hidden: false, **)
    authorize! Vacancy.new, :index?

    query = run_operation(Vacancy::Operation::BuildSearchQuery,
                          { include_tags: params[:include_tags],
                            include_ops:  params[:include_ops],
                            exclude_tags: params[:exclude_tags],
                            must_tags:,
                            source_ids:,
                            exclude_vacancy_ids: (hidden_vacancy_ids(current_user) if exclude_hidden) }).model
    per_page = per_page.to_i.clamp(1, MAX_PER_PAGE)
    page     = params[:page].to_i.clamp(1, self.class.last_reachable_page(per_page))

    raw = Vacancy.search(search_body(query, page, per_page, SORTS.fetch(sort.to_s, SORTS['newest']))).response

    total = raw.dig('hits', 'total', 'value').to_i
    ids   = raw['hits']['hits'].map { |h| h['_id'].to_i }
    by_id = Vacancy.includes(:source).where(id: ids).index_by(&:id)

    self.model = WillPaginate::Collection.create(page, per_page, total) do |pager|
      pager.replace(ids.filter_map { |id| by_id[id] })
    end
  end

  private

  # Rides the unique (user_id, vacancy_id) index; a user hides at most thousands.
  def hidden_vacancy_ids(current_user)
    return [] if current_user.nil?

    current_user.hidden_vacancies.pluck(:vacancy_id)
  end

  def search_body(query, page, per_page, sort)
    {
      query:            query,
      sort:             sort,
      from:             (page - 1) * per_page,
      size:             per_page,
      track_total_hits: true
    }
  end
end
