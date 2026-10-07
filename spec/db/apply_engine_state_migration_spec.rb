# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261007000001_apply_engine_state")
require Rails.root.join("db/migrate/20261007000004_remove_legacy_status_from_applies")

# Postgres DDL is transactional: the example (inside the fixture transaction) rolls the table back to its legacy
# shape, inserts legacy rows, runs the real migration and restores the schema when the transaction rolls back.
RSpec.describe ApplyEngineState do
  let(:connection) { ActiveRecord::Base.connection }
  let(:user) { create(:user) }
  let(:vacancy) { create(:vacancy, source: create(:source)) }
  let(:rows) { {} }

  # state :cancelled keeps the rows clear of the active-apply unique index while the legacy shape is rebuilt
  def make_apply(vacancy:)
    create(:apply, user:, vacancy:, state: :cancelled, source_profile: create(:source_profile, user:, source: vacancy.source))
  end

  def other_vacancy
    create(:vacancy, source: vacancy.source)
  end

  def run(migration, direction)
    ActiveRecord::Migration.suppress_messages { migration.migrate(direction) }
  end

  def legacy_update(apply, status:, error: nil, updated_at: Time.current)
    connection.execute(
      "UPDATE applies SET status = #{status || 'NULL'}, error = #{connection.quote(error)}, " \
      "updated_at = #{connection.quote(updated_at)} WHERE id = #{apply.id}"
    )
  end

  def row(apply)
    connection.select_one("SELECT * FROM applies WHERE id = #{apply.id}")
  end

  before do
    # failed_a, sending_old and sending_new share one (user, vacancy) on purpose
    rows[:failed_a] = make_apply(vacancy:)
    rows[:failed_b] = make_apply(vacancy: other_vacancy)
    rows[:sending_old] = make_apply(vacancy:)
    rows[:sending_new] = make_apply(vacancy:)
    rows[:completed] = make_apply(vacancy: other_vacancy)
    rows[:null_status] = make_apply(vacancy: other_vacancy)

    run(RemoveLegacyStatusFromApplies.new, :down)
    run(described_class.new, :down)

    old = 2.days.ago
    legacy_update(rows[:failed_a], status: 10, error: "boom", updated_at: old)
    legacy_update(rows[:failed_b], status: 14, error: "bad form", updated_at: old)
    legacy_update(rows[:sending_old], status: 3, updated_at: old)
    legacy_update(rows[:sending_new], status: 3, updated_at: 1.day.ago)
    legacy_update(rows[:completed], status: 4, updated_at: old)
    legacy_update(rows[:null_status], status: nil, updated_at: old)

    run(described_class.new, :up)
  end

  after { Apply.reset_column_information }

  it "backfills the lifecycle state from the legacy status" do
    expect(row(rows[:failed_a])).to include("state" => 6, "submit_claimed_at" => nil)
    expect(row(rows[:failed_b])["state"]).to eq(6)
    expect(row(rows[:completed])).to include("state" => 5, "submitted_via" => "engine")
    expect(row(rows[:completed])["submitted_at"]).to be_present
    expect(row(rows[:null_status])["state"]).to eq(6)
  end

  it "keeps the claim only on the newest sending_cv per (user, vacancy)" do
    expect(row(rows[:sending_new])).to include("state" => 8)
    expect(row(rows[:sending_new])["submit_claimed_at"]).to be_present
    expect(row(rows[:sending_old])).to include("state" => 6, "submit_claimed_at" => nil)
  end

  it "writes failure codes" do
    failure = ->(key) { JSON.parse(row(rows[key])["failure"]) }
    expect(failure.call(:failed_a)).to include("code" => "legacy_failure", "legacy_status" => 10, "detail" => "boom")
    expect(failure.call(:sending_new)).to include("code" => "outcome_unknown", "legacy_status" => 3)
    expect(failure.call(:null_status)).to include("code" => "worker_lost")
    expect(row(rows[:completed])["failure"]).to be_nil
  end

  it "creates NOT NULL state and every index" do
    column = connection.columns(:applies).find { |c| c.name == "state" }
    expect(column.null).to be false
    expect(column.default).to eq("0")

    expect(connection.indexes(:applies).map(&:name)).to include(
      "index_applies_one_active_per_vacancy", "index_applies_one_open_claim_per_vacancy",
      "index_applies_on_user_state", "index_applies_on_user_created",
      "index_applies_stale_candidates", "index_applies_waiting_updated"
    )
  end
end
