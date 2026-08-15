# frozen_string_literal: true

# Dispatches submission: fields fetched via an ATS adapter are submitted through
# the same adapter's API endpoint; browser-sourced fields go through the
# perceive→act→verify loop (External::Generic) in the live session. An adapter
# failure at this stage fails the apply — a job retry re-enters the adapter.
class Apply::Operation::External::Submit < Apply::Operation::Base
  def start_status
    :sending_cv
  end

  def error_status
    :failed_sending_cv
  end

  def success_status
    :completed
  end

  private

  def run!(apply:, handler:, **)
    adapter = apply.fields_source == 'adapter' ? Apply::ExternalAts::Base.for(apply.ats) : nil

    if adapter
      adapter.submit(apply:, handler:)
    else
      Apply::Operation::External::Generic.call(apply:, handler:) # raises on failure
    end
  end
end
