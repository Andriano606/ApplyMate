# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Engine::CheckApplyKey do
  subject(:check) { described_class.call(ctx:).model }

  let(:user) { create(:user) }
  let(:apply) { create(:apply, user:) }
  let(:ctx) { engine_context(apply) }
  let(:jid) { '20587adf-cf02-473e-8a80-7b009711a2cf' }
  let(:ashby_match) do
    Apply::Operation::Engine::Detect::Match.new(key: 'ashby', confidence: 0.98, captures: { 'slug' => 'preply', 'jid' => jid },
                                                frame_path: nil, from_alias: false, probable: nil)
  end

  def previous_apply(key, **attributes)
    create(:apply, :completed, user:, apply_key: key, **attributes)
  end

  context 'with a known platform' do
    before { ctx.adopt_match!(ashby_match) }

    it "returns the platform's posting key when nothing matches" do
      expect(check).to eq("ashby:preply:#{jid}")
    end

    it 'halts with already_applied (previous hashid) for a completed apply with the same key' do
      previous = previous_apply("ashby:preply:#{jid}")

      expect { check }.to raise_error(Apply::Operation::Engine::Halt) { |halt|
        expect(halt).to have_attributes(code: :already_applied, detail: previous.hashid)
      }
    end

    it 'counts submit_unverified and claimed applies as applied' do
      previous_apply("ashby:preply:#{jid}", state: :submit_unverified, submitted_at: nil, submitted_via: nil)

      expect { check }.to raise_error(Apply::Operation::Engine::Halt)
    end

    it 'counts an apply holding a submit claim' do
      previous_apply("ashby:preply:#{jid}", state: :failed, submitted_at: nil, submit_claimed_at: 1.hour.ago)

      expect { check }.to raise_error(Apply::Operation::Engine::Halt)
    end

    it 'ignores failed / cancelled applies without a claim, other users and other keys' do
      previous_apply("ashby:preply:#{jid}", state: :failed, submitted_at: nil)
      previous_apply("ashby:preply:#{jid}", state: :cancelled, submitted_at: nil)
      create(:apply, :completed, apply_key: "ashby:preply:#{jid}")
      previous_apply('ashby:preply:other')

      expect(check).to eq("ashby:preply:#{jid}")
    end

    it 'passes once the user confirmed the duplicate' do
      previous_apply("ashby:preply:#{jid}")
      apply.update_column(:duplicate_confirmed_at, Time.current)

      expect(check).to eq("ashby:preply:#{jid}")
    end
  end

  context 'with the generic platform' do
    before { ctx.adopt_match!(Apply::Operation::Engine::Detect::Match.generic) }

    it 'keys on the normalized form URL (host without www, path without query and trailing slash)' do
      ctx.form_url = 'https://WWW.Example.com/careers/apply/?job=1#form'

      expect(check).to eq('example.com/careers/apply')
    end

    it 'has no key while the form URL is unknown (the entry URL is a job-board redirector)' do
      previous_apply('dou.ua/goto/vacancy')

      expect(check).to be_nil
    end
  end
end
