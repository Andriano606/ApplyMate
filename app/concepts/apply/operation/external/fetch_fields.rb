# frozen_string_literal: true

# Dispatches field extraction: a detected ATS with an adapter gets its fields
# from the ATS API (deterministic, roles pre-filled, no AI); anything else —
# and any adapter failure — falls back to the browser path (PrepareSession).
# The adapter is an optimization, the browser path is the guarantee.
class Apply::Operation::External::FetchFields < Apply::Operation::Base
  def start_status
    :fetching_form
  end

  def error_status
    :failed_fetching_form
  end

  private

  def run!(apply:, handler:, **)
    adapter = Apply::ExternalAts::Base.for(apply.ats)

    if adapter
      begin
        fields = adapter.fetch_fields(apply:)
        apply.update!(inputs: fields, fields_source: 'adapter')
        return
      rescue Apply::ExternalAts::Base::AdapterError => e
        Rails.logger.warn("ATS adapter #{apply.ats} failed, falling back to browser: #{e.message}")
      end
    end

    Apply::Operation::External::PrepareSession.call(apply:, handler:) # raises on failure
    apply.update!(fields_source: 'browser')
  end
end
