# frozen_string_literal: true

# MCP `list_sources`: the job boards vacancies come from, with live counts.
class Mcp::Operation::ListSources < ApplyMate::Operation::Base
  def perform!(**)
    authorize! Vacancy.new, :index?

    counts = run_operation(Vacancy::Operation::CountBySource, {}).model
    self.model = Source.order(:name).map do |source|
      ApplyMate::Operation::Struct.new(source:, count: counts[source.id].to_i)
    end
  end
end
