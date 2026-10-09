# frozen_string_literal: true

require "rails_helper"

RSpec.describe ApplyStep, type: :model do
  it "maps the states" do
    expect(described_class.states).to eq("running" => 0, "succeeded" => 1, "failed" => 2, "skipped" => 3)
  end

  describe "#duration" do
    it "is nil while running" do
      expect(build(:apply_step, finished_at: nil).duration).to be_nil
    end

    it "is finished_at - started_at" do
      now = Time.current
      step = build(:apply_step, started_at: now, finished_at: now + 2.5)
      expect(step.duration).to eq(2.5)
    end
  end

  describe ".chronological" do
    it "orders by attempt then position" do
      apply = create(:apply)
      late = create(:apply_step, apply:, attempt: 2, position: 1)
      second = create(:apply_step, apply:, attempt: 1, position: 2)
      first = create(:apply_step, apply:, attempt: 1, position: 1)
      expect(apply.apply_steps.chronological).to eq([ first, second, late ])
    end
  end

  it "is destroyed with its apply" do
    step = create(:apply_step)
    expect { step.apply.destroy }.to change(described_class, :count).by(-1)
  end
end
