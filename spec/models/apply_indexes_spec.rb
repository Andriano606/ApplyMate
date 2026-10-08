# frozen_string_literal: true

require "rails_helper"

RSpec.describe "applies partial indexes" do
  def indexdef(name)
    ActiveRecord::Base.connection.select_value(
      "SELECT indexdef FROM pg_indexes WHERE tablename = 'applies' AND indexname = #{ActiveRecord::Base.connection.quote(name)}"
    )
  end

  def ints(names)
    names.map { |n| Apply.states.fetch(n) }.sort
  end

  def in_list(definition)
    definition[/state = ANY \(ARRAY\[([\d, ]+)\]\)|state IN \(([\d, ]+)\)/]
    (Regexp.last_match(1) || Regexp.last_match(2)).scan(/\d+/).map(&:to_i).sort
  end

  it "one_active_per_vacancy covers ACTIVE_STATES" do
    definition = indexdef("index_applies_one_active_per_vacancy")
    expect(definition).to include("UNIQUE")
    expect(in_list(definition)).to eq(ints(Apply::ACTIVE_STATES))
  end

  it "stale_candidates covers IN_PROGRESS_STATES" do
    definition = indexdef("index_applies_stale_candidates")
    expect(definition).to include("COALESCE(heartbeat_at, updated_at)")
    expect(in_list(definition)).to eq(ints(Apply::IN_PROGRESS_STATES))
  end

  it "waiting_updated covers needs_review and needs_human" do
    expect(in_list(indexdef("index_applies_waiting_updated"))).to eq(ints(%w[needs_review needs_human]))
  end

  it "remind_candidates covers WAITING_STATES and REMINDER_DUE_SQL" do
    definition = indexdef("index_applies_remind_candidates")
    expect(in_list(definition)).to eq(ints(Apply::WAITING_STATES))
    expect(definition).to include("reminded_at IS NULL", "reminded_at < updated_at")
  end

  it "one_open_claim_per_vacancy excludes cancelled" do
    definition = indexdef("index_applies_one_open_claim_per_vacancy")
    expect(definition).to include("UNIQUE", "submit_claimed_at IS NOT NULL", "submitted_at IS NULL")
    expect(definition).to match(/state <> #{Apply.states.fetch('cancelled')}\b/)
  end

  it "has the user lookup indexes" do
    expect(indexdef("index_applies_on_user_state")).to include("(user_id, state)")
    expect(indexdef("index_applies_on_user_created")).to include("(user_id, created_at)")
  end

  it "has the user apply_key partial index" do
    definition = indexdef("index_applies_on_user_apply_key")
    expect(definition).to include("(user_id, apply_key)", "apply_key IS NOT NULL")
  end

  describe "apply_steps partial indexes" do
    def step_indexdef(name)
      ActiveRecord::Base.connection.select_value(
        "SELECT indexdef FROM pg_indexes WHERE tablename = 'apply_steps' AND indexname = #{ActiveRecord::Base.connection.quote(name)}"
      )
    end

    it "resume_lookup covers succeeded steps" do
      definition = step_indexdef("index_apply_steps_resume_lookup")
      expect(definition).to include("(apply_id, key, input_digest)")
      expect(definition).to match(/state = #{ApplyStep.states.fetch('succeeded')}\b/)
    end

    it "prunable_trace covers steps with a trace" do
      definition = step_indexdef("index_apply_steps_prunable_trace")
      expect(definition).to include("(finished_at)", "trace IS NOT NULL")
    end
  end
end
