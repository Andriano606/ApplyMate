# frozen_string_literal: true

# An engine stage (design §10.2): an Apply::Operation::Base step that the Runner may SKIP on a later attempt.
#
#   self.input_digest(ctx, **options)  nil -> the step always runs; otherwise a succeeded apply_steps row with the
#                                      same key and digest (any attempt) lets the Runner skip it and call `restore`
#   self.restore(ctx, result)          rehydrates the in-memory ctx from that row's stored step result
#   step_result(**data)                (in run!) what `restore` will get back: the Runner stores it in
#                                      apply_steps.result (read from the operation result's :step_result)
class Apply::Operation::Stage::Base < Apply::Operation::Base
  class << self
    def input_digest(_ctx, **)
      nil
    end

    def restore(_ctx, _result)
      nil
    end
  end

  private

  def step_result(**data)
    result[:step_result] = data.deep_stringify_keys
  end
end
