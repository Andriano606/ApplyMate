# AI budget and token accounting of the engine (CallAi), and the live-input handshake of the EmailCode gate.
#   ai_calls          AI calls of the current attempt (StartContext resets it)
#   ai_calls_total    AI calls over the apply's life (never reset)
#   ai_input_tokens, ai_output_tokens   tokens over the apply's life; apply_steps carry the per-step share
#   input_request, input_response       the awaiting-input handshake (ProvideInput)
# Every write rides the primary key, so no index.
class AddAiBudgetAndInputRequestToApplies < ActiveRecord::Migration[8.1]
  def change
    add_column :applies, :ai_calls, :integer, null: false, default: 0
    add_column :applies, :ai_calls_total, :integer, null: false, default: 0
    add_column :applies, :ai_input_tokens, :bigint, null: false, default: 0
    add_column :applies, :ai_output_tokens, :bigint, null: false, default: 0
    add_column :applies, :input_request, :jsonb
    add_column :applies, :input_response, :jsonb

    add_column :apply_steps, :ai_input_tokens, :integer, null: false, default: 0
    add_column :apply_steps, :ai_output_tokens, :integer, null: false, default: 0
  end
end
