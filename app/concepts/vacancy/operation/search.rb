# frozen_string_literal: true

# params: { include_tags: ['rails', 'ruby', 'react'], include_ops: ['and', 'or'], exclude_tags: ['vue'] }
# result: ('rails' AND 'ruby') OR 'react'

class Vacancy::Operation::Search < ApplyMate::Operation::Base
  SEARCH_FIELDS = %w[title company_name description].freeze

  def perform!(params:, current_user:, **)
    authorize! Vacancy.new, :index?

    include_tags = normalize_tags(params[:include_tags])
    include_ops  = parse_ops(params[:include_ops], include_tags.size)
    exclude_tags = normalize_tags(params[:exclude_tags])
    page         = [ params[:page].to_i, 1 ].max
    per_page     = WillPaginate.per_page

    raw = Vacancy.search(build_body(include_tags:, include_ops:, exclude_tags:, page:, per_page:)).response

    total = raw.dig('hits', 'total', 'value').to_i
    ids   = raw['hits']['hits'].map { |h| h['_id'].to_i }
    by_id = Vacancy.where(id: ids).index_by(&:id)

    self.model = WillPaginate::Collection.create(page, per_page, total) do |pager|
      pager.replace(ids.filter_map { |id| by_id[id] })
    end
  end

  private

  def normalize_tags(param)
    Array.wrap(param).flat_map { |v| v.to_s.split(',') }.map(&:strip).reject(&:blank?)
  end

  def parse_ops(param, tags_count)
    return [] if tags_count <= 1

    normalize_tags(param).map(&:downcase)
  end

  def build_body(include_tags:, include_ops:, exclude_tags:, page:, per_page:)
    {
      query: { bool: { must: [ build_include(include_tags, include_ops) ], must_not: build_excludes(exclude_tags) } },
      sort:  [ { vacancy_id: { order: 'desc' } } ],
      from:  (page - 1) * per_page,
      size:  per_page
    }
  end

  def build_include(tags, ops)
    return { match_all: {} } if tags.empty?
    return phrase_clause(tags.first) if tags.one?

    groups = group_by_and(tags, ops)
    or_clauses = groups.map do |group|
      group.one? ? phrase_clause(group.first) : { bool: { must: group.map { |t| phrase_clause(t) } } }
    end

    or_clauses.one? ? or_clauses.first : { bool: { should: or_clauses, minimum_should_match: 1 } }
  end

  def group_by_and(tags, ops)
    groups = [ [ tags.first ] ]
    (1...tags.size).each do |i|
      (ops[i - 1] || 'and') == 'and' ? groups.last << tags[i] : groups << [ tags[i] ]
    end
    groups
  end

  def phrase_clause(tag)
    { multi_match: { query: tag, fields: SEARCH_FIELDS, type: 'phrase' } }
  end

  def build_excludes(tags)
    tags.map do |tag|
      if tag.split.one?
        { bool: { should: SEARCH_FIELDS.map { |f| { wildcard: { f => { value: "#{tag}*", case_insensitive: true } } } } } }
      else
        { multi_match: { query: tag, fields: SEARCH_FIELDS, type: 'phrase' } }
      end
    end
  end
end
