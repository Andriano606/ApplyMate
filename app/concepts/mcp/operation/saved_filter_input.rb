# frozen_string_literal: true

# Shared by the MCP operations that write saved filters. The web search bar always sends a
# consistent tags/ops state; a model calling the tools can easily not, and
# Vacancy::Operation::BuildSearchQuery would then silently search for something else (it splits
# every tag on commas and fills missing ops with `and`). So the input is checked here and refused
# with a readable message instead.
module Mcp::Operation::SavedFilterInput
  private

  # Only the token user's own filters: someone else's id reads as unknown, like a stale one.
  def find_saved_filter(id, current_user)
    filter = current_user.saved_filters.find_by_hashid(id.to_s)
    return filter if filter

    skip_authorize # nothing to authorize against; the refusal below is the answer
    refuse!(I18n.t('mcp.errors.unknown_saved_filter', id:))
  end

  # The filter state to save. Omitted parts keep `current`'s values (update); new include_tags
  # without include_ops get `and` between every tag — old ops would no longer line up.
  def filter_state(params, current = nil)
    include_tags = params.key?(:include_tags) ? clean_tags(params[:include_tags]) : Array(current&.include_tags)
    exclude_tags = params.key?(:exclude_tags) ? clean_tags(params[:exclude_tags]) : Array(current&.exclude_tags)
    include_ops  = clean_ops(params, include_tags, current)

    refuse!(I18n.t('mcp.errors.saved_filter_empty')) if include_tags.empty? && exclude_tags.empty?

    { include_tags:, include_ops:, exclude_tags: }
  end

  def clean_tags(values)
    tags = Array(values).map { |tag| tag.to_s.strip }.reject(&:blank?)
    with_comma = tags.find { |tag| tag.include?(',') }
    refuse!(I18n.t('mcp.errors.saved_filter_tag_comma', tag: with_comma)) if with_comma
    tags
  end

  def clean_ops(params, include_tags, current)
    # Neither changes: keep the stored ops as they are (a rename must not fail on old web data).
    return Array(current.include_ops) if current && !params.key?(:include_tags) && !params.key?(:include_ops)

    expected = [ include_tags.size - 1, 0 ].max
    ops = params.key?(:include_ops) ? Array(params[:include_ops]) : Array.new(expected, 'and') # values: tool schema enum

    if ops.size != expected
      refuse!(I18n.t('mcp.errors.saved_filter_ops_count', count: ops.size, tags: include_tags.size, expected:))
    end
    ops
  end

  # Runs the web operation and turns its validation errors (e.g. a taken name) into one message.
  def run_web_operation(operation, params, current_user)
    sub_result = run_operation(operation, { params:, current_user:, manually_handle_errors: true })
    return sub_result.model unless sub_result.failure?

    messages = sub_result.model.respond_to?(:errors) ? sub_result.model.errors.full_messages : []
    refuse!(messages.presence&.join('. ') || sub_result.error_message)
  end

  def refuse!(message)
    add_error(:invalid, message)
    raise ActiveRecord::RecordInvalid
  end
end
