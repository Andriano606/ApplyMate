# frozen_string_literal: true

# params: { include_tags: ['rails', 'ruby', 'react'], include_ops: ['and', 'or'], exclude_tags: ['vue'] }
# result: ('rails' AND 'ruby') OR 'react'
#
# Ops precedence: 'g_or' joins adjacent tags into an explicit parenthesized OR
# group (tightest), then 'and' binds tighter than 'or':
#   tags: [embedded, stm32, remote, віддалено], ops: [and, and, g_or]
#   => embedded AND stm32 AND (remote OR віддалено)
#
# Each tag may itself be a boolean expression with parentheses, parsed by
# Vacancy::SearchExpression: 'embedded і stm32 і (remote або віддалено)'.

class Vacancy::Operation::Search < ApplyMate::Operation::Base
  SEARCH_FIELDS = %w[title company_name description].freeze
  OPS = %w[and or g_or].freeze

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
      query:            { bool: { must: [ build_include(include_tags, include_ops) ], must_not: build_excludes(exclude_tags) } },
      sort:             [ { vacancy_id: { order: 'desc' } } ],
      from:             (page - 1) * per_page,
      size:             per_page,
      track_total_hits: true
    }
  end

  def build_include(tags, ops)
    return { match_all: {} } if tags.empty?
    return include_clause(tags.first) if tags.one?

    units, unit_ops = split_group_units(tags, ops)
    clauses = units.map do |unit|
      unit.one? ? include_clause(unit.first) : or_clause(unit.map { |tag| include_clause(tag) })
    end

    build_boolean(clauses, unit_ops)
  end

  # tags: [a, b, c, d], ops: [and, g_or, or] => units: [[a], [b, c], [d]], unit_ops: [and, or]
  def split_group_units(tags, ops)
    units    = [ [ tags.first ] ]
    unit_ops = []

    (1...tags.size).each do |i|
      if ops[i - 1] == 'g_or'
        units.last << tags[i]
      else
        unit_ops << (ops[i - 1] || 'and')
        units << [ tags[i] ]
      end
    end

    [ units, unit_ops ]
  end

  def build_boolean(clauses, ops)
    groups = [ [ clauses.first ] ]
    (1...clauses.size).each do |i|
      (ops[i - 1] || 'and') == 'and' ? groups.last << clauses[i] : groups << [ clauses[i] ]
    end

    or_clauses = groups.map { |group| group.one? ? group.first : { bool: { must: group } } }
    or_clauses.one? ? or_clauses.first : or_clause(or_clauses)
  end

  def or_clause(clauses)
    { bool: { should: clauses, minimum_should_match: 1 } }
  end

  def include_clause(tag)
    expression_clause(tag) { |phrase| phrase_clause(phrase) }
  end

  def phrase_clause(tag)
    { multi_match: { query: tag, fields: SEARCH_FIELDS, type: 'phrase' } }
  end

  def build_excludes(tags)
    tags.map { |tag| expression_clause(tag) { |phrase| exclude_phrase_clause(phrase) } }
  end

  def exclude_phrase_clause(phrase)
    if phrase.split.one?
      { bool: { should: SEARCH_FIELDS.map { |f| { wildcard: { f => { value: "#{phrase}*", case_insensitive: true } } } } } }
    else
      phrase_clause(phrase)
    end
  end

  def expression_clause(tag, &leaf)
    node_clause(Vacancy::SearchExpression.parse(tag), &leaf)
  end

  def node_clause(node, &leaf)
    case node
    when Vacancy::SearchExpression::And
      { bool: { must: node.nodes.map { |n| node_clause(n, &leaf) } } }
    when Vacancy::SearchExpression::Or
      or_clause(node.nodes.map { |n| node_clause(n, &leaf) })
    else
      yield node.text
    end
  end
end
