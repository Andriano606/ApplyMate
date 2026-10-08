# frozen_string_literal: true

require "rails_helper"

RSpec.describe Apply, type: :model do
  let(:source1) { create(:source, name: "Source 1") }
  let(:source2) { create(:source, name: "Source 2") }
  let(:user) { User.create!(email: unique_email("test"), name: "Test User", provider: "google_oauth2", uid: "123") }
  let(:vacancy) { create(:vacancy, source: source1) }
  let(:source_profile) { SourceProfile.create!(user: user, source: source1, name: "Profile 1", auth_method: :session_id) }
  let(:user_profile) { UserProfile.create!(user: user, name: "User Profile", cv: "My CV") }
  let(:ai_integration) { AiIntegration.create!(user: user, provider: "gemini", model: "gemini-pro", api_key: "secret") }

  subject(:apply) do
    described_class.new(
      user: user,
      vacancy: vacancy,
      source_profile: source_profile,
      user_profile: user_profile,
      ai_integration: ai_integration,
      state: :running
    )
  end

  describe "validations" do
    context "when source_profile and vacancy have the same source" do
      it "is valid" do
        expect(apply).to be_valid
      end
    end

    context "when source_profile and vacancy have different sources" do
      let(:vacancy) { create(:vacancy, source: source2) }

      it "is invalid" do
        expect(apply).not_to be_valid
        expect(apply.errors[:source_profile]).to include("must belong to the same source as the vacancy")
      end
    end

    context "when vacancy is missing" do
      before { apply.vacancy = nil }

      it "does not add source mismatch error" do
        apply.valid?
        expect(apply.errors[:source_profile]).not_to include("must belong to the same source as the vacancy")
      end
    end

    context "when source_profile is missing" do
      before { apply.source_profile = nil }

      it "does not add source mismatch error" do
        apply.valid?
        expect(apply.errors[:source_profile]).not_to include("must belong to the same source as the vacancy")
      end
    end
  end

  describe "enum" do
    it "maps the lifecycle states" do
      expect(described_class.states).to eq(
        "queued" => 0, "running" => 1, "waiting_capacity" => 2, "needs_review" => 3, "needs_human" => 4,
        "completed" => 5, "failed" => 6, "unsupported" => 7, "submit_unverified" => 8, "cancelled" => 9
      )
    end

    it "defaults to queued" do
      expect(create(:apply).state).to eq("queued")
    end
  end

  describe "predicates" do
    it "in_progress? is true for queued, running and waiting_capacity" do
      expect(%i[queued running waiting_capacity].map { |s| build(:apply, state: s).in_progress? }).to all(be true)
      expect(build(:apply, state: :needs_human)).not_to be_in_progress
    end

    it "needs_attention? covers review, human, failed, unsupported and submit_unverified" do
      attention = %i[needs_review needs_human failed unsupported submit_unverified]
      expect(attention.map { |s| build(:apply, state: s).needs_attention? }).to all(be true)
      expect(build(:apply, state: :completed)).not_to be_needs_attention
    end

    it "claimed? reflects submit_claimed_at" do
      expect(build(:apply)).not_to be_claimed
      expect(build(:apply, :claimed)).to be_claimed
    end

    it "resumable? needs a resumable state and no claim" do
      expect(build(:apply, :failed)).to be_resumable
      expect(build(:apply, :needs_human)).to be_resumable
      expect(build(:apply, :failed, submit_claimed_at: Time.current)).not_to be_resumable
      expect(build(:apply, :completed)).not_to be_resumable
    end

    it "resumable? is false while a sibling apply of the vacancy claimed or submitted" do
      apply = create(:apply, :failed)
      expect(apply).to be_resumable

      create(:apply, :completed, user: apply.user, vacancy: apply.vacancy, source_profile: apply.source_profile)
      expect(apply).not_to be_resumable
    end

    it "wait_expires_at follows the waiting state's timeout" do
      now = Time.current.change(usec: 0)
      expect(build(:apply, :needs_human, updated_at: now).wait_expires_at).to eq(now + Apply::HUMAN_TIMEOUT)
      expect(build(:apply, state: :needs_review, updated_at: now).wait_expires_at).to eq(now + Apply::REVIEW_TIMEOUT)
      expect(build(:apply, :failed, updated_at: now).wait_expires_at).to be_nil
    end

    it "reminded? holds only for the current wait" do
      now = Time.current
      expect(build(:apply, updated_at: now, reminded_at: now)).to be_reminded
      expect(build(:apply, updated_at: now, reminded_at: now - 1.second)).not_to be_reminded
      expect(build(:apply, updated_at: now)).not_to be_reminded
    end
  end

  describe ".with_cv_or_generating_cv" do
    it "includes generating, attached-cv and excludes failed without cv" do
      generating = create(:apply, :running)
      with_cv = create(:apply, :failed)
      with_cv.cv.attach(io: StringIO.new("pdf"), filename: "cv.pdf", content_type: "application/pdf")
      failed = create(:apply, :failed)
      running_other_stage = create(:apply, :running, stage: "fetch_details")

      result = described_class.with_cv_or_generating_cv
      expect(result).to include(generating, with_cv)
      expect(result).not_to include(failed, running_other_stage)
    end
  end

  describe ".reapply_guarded" do
    let(:apply) { create(:apply, :completed) }

    it "finds claimed or submitted applies of the vacancy and user" do
      expect(described_class.reapply_guarded(vacancy: apply.vacancy, user: apply.user)).to contain_exactly(apply)
    end

    it "ignores cancelled, unsubmitted and foreign applies" do
      cancelled = create(:apply, :claimed, state: :cancelled)
      failed = create(:apply, :failed)
      expect(described_class.reapply_guarded(vacancy: cancelled.vacancy, user: cancelled.user)).to be_empty
      expect(described_class.reapply_guarded(vacancy: failed.vacancy, user: failed.user)).to be_empty
      expect(described_class.reapply_guarded(vacancy: apply.vacancy, user: create(:user))).to be_empty
    end
  end

  describe ".attention_count_for" do
    let(:cache) { ActiveSupport::Cache::MemoryStore.new }

    before { allow(Rails).to receive(:cache).and_return(cache) }

    it "is cached until touch_user_applies_changed_at! is called" do
      apply = create(:apply, :failed)
      user = apply.user
      expect(described_class.attention_count_for(user)).to eq(1)

      create(:apply, :needs_human, user:, vacancy: create(:vacancy, source: apply.vacancy.source),
                                   source_profile: apply.source_profile)
      expect(described_class.attention_count_for(user)).to eq(1)

      travel(1.second) { apply.touch_user_applies_changed_at! }
      expect(described_class.attention_count_for(user.reload)).to eq(2)
    end

    it "gets a new key for a second transition within the same second" do
      apply = create(:apply, :failed)
      user = apply.user
      freeze_time
      user.update_columns(applies_changed_at: Time.current.change(usec: 100_000))
      expect(described_class.attention_count_for(user)).to eq(1)

      create(:apply, :needs_human, user:, vacancy: create(:vacancy, source: apply.vacancy.source),
                                   source_profile: apply.source_profile)
      user.update_columns(applies_changed_at: Time.current.change(usec: 700_000))
      expect(described_class.attention_count_for(user)).to eq(2)
    end
  end

  describe "#platform_known?" do
    it "is false without a platform and for generic" do
      expect(build(:apply, platform: nil)).not_to be_platform_known
      expect(build(:apply, platform: "generic")).not_to be_platform_known
    end

    it "is true for a registered platform" do
      expect(build(:apply, platform: "ashby")).to be_platform_known
    end
  end

  describe "#question_labels" do
    let(:field) do
      lambda do |id, kind, label|
        Apply::Field.from_h(id:, kind:, label:).to_h
      end
    end

    it "reads textarea and rich_text fields with a label" do
      apply = build(:apply, fields: [ field.call("a", "textarea", "Why us?"), field.call("b", "rich_text", "Tell us"),
                                      field.call("c", "text", "Name"), field.call("d", "textarea", nil) ],
                            inputs: [ { "tag" => "textarea", "label" => "Legacy" } ])

      expect(apply.question_labels).to eq([ "Why us?", "Tell us" ])
    end

    it "falls back to legacy inputs when fields are blank" do
      apply = build(:apply, inputs: [ { "tag" => "textarea", "label" => "Legacy" }, { "tag" => "input", "label" => "Name" } ])

      expect(apply.question_labels).to eq([ "Legacy" ])
    end
  end

  describe "#field_list / #answer_for" do
    it "builds Apply::Field objects and looks up answers by field id" do
      apply = build(:apply, fields: [ Apply::Field.from_h(id: "a", kind: "text").to_h ],
                            answers: { "a" => { "value" => "x", "source" => "fact" } })

      expect(apply.field_list.map(&:id)).to eq([ "a" ])
      expect(apply.answer_for(:a)).to eq("value" => "x", "source" => "fact")
      expect(apply.answer_for("zzz")).to be_nil
    end
  end
end
