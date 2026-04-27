# frozen_string_literal: true

class Vacancy::Operation::Index < ApplyMate::Operation::Base
  SEARCH_FIELDS       = %w[title company_name description].freeze
  SEARCH_FIELDS_EXACT = %w[title.keyword company_name.keyword description.keyword].freeze

  def perform!(params:, current_user:, **)
    authorize! Vacancy.new, :index?
    query    = params[:query].presence
    exclude  = params[:exclude].presence
    page     = [ params[:page].to_i, 1 ].max
    per_page = WillPaginate.per_page

    raw = Vacancy.search(build_body(query:, exclude:, page:, per_page:)).response

    total = raw.dig('hits', 'total', 'value').to_i
    ids   = raw['hits']['hits'].map { |h| h['_id'].to_i }
    by_id = Vacancy.where(id: ids).index_by(&:id)

    self.model = WillPaginate::Collection.create(page, per_page, total) do |pager|
      pager.replace(ids.filter_map { |id| by_id[id] })
    end
  end

  private

  def build_body(query:, exclude:, page:, per_page:)
    must     = query   ? [ { multi_match: { query:, fields: SEARCH_FIELDS } } ] : [ { match_all: {} } ]
    must_not = exclude ? exclude.split.map { |w|
      { bool: { should: SEARCH_FIELDS.map { |f| { wildcard: { f => { value: "#{w}*", case_insensitive: true } } } } } }
    } : []

    {
      query: { bool: { must:, must_not: } },
      sort:  [ { created_at: { order: 'desc' } } ],
      from:  (page - 1) * per_page,
      size:  per_page
    }
  end
end
