# frozen_string_literal: true

# MCP `search_vacancies`: a free-text query, optionally on top of one of the
# user's saved filters, narrowed by source. The search itself is
# Vacancy::Operation::Search — the same query builder as the web search bar.
# The result model is its WillPaginate collection.
class Mcp::Operation::SearchVacancies < ApplyMate::Operation::Base
  DEFAULT_PER_PAGE = 20

  def perform!(params:, current_user:, **)
    authorize! Vacancy.new, :index?

    saved_filter = resolve_saved_filter(params[:saved_filter_id], current_user)
    sources      = resolve_sources(params[:sources])

    search_params = {
      include_tags: saved_filter&.include_tags,
      include_ops:  saved_filter&.include_ops,
      exclude_tags: [ *saved_filter&.exclude_tags, *params[:exclude] ],
      page:         params[:page]
    }
    self.model = run_operation(Vacancy::Operation::Search,
                               { params: search_params,
                                 current_user:,
                                 per_page:   params[:per_page] || DEFAULT_PER_PAGE,
                                 sort:       params[:sort] || 'newest',
                                 must_tags:  params[:query],
                                 source_ids: sources&.map(&:id) }).model
  end

  private

  def resolve_saved_filter(id, current_user)
    return if id.blank?

    current_user.saved_filters.find_by_hashid(id) ||
      fail!(I18n.t('mcp.errors.unknown_saved_filter', id:))
  end

  # Sources are few (one per job board), so match names and ids in Ruby.
  def resolve_sources(values)
    values = Array(values).map(&:to_s).compact_blank
    return if values.empty?

    all     = Source.order(:name).to_a
    matched = all.select { |source| values.any? { |v| v == source.to_param || v.casecmp?(source.name) } }
    unknown = values.reject { |v| all.any? { |source| v == source.to_param || v.casecmp?(source.name) } }
    return matched if unknown.empty?

    fail!(I18n.t('mcp.errors.unknown_sources', sources: unknown.join(', '), known: all.map(&:name).join(', ')))
  end

  def fail!(message)
    add_error(:invalid, message)
    raise ActiveRecord::RecordInvalid
  end
end
