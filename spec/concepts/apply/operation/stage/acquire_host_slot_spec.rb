# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Stage::AcquireHostSlot do
  subject(:run) { described_class.call(ctx:) }

  let(:apply) { create(:apply) }
  let(:ctx) { engine_context(apply) }
  let(:ashby_match) do
    Apply::Operation::Engine::Detect::Match.new(key: 'ashby', confidence: 0.95, captures: { 'slug' => 'preply', 'jid' => 'x' },
                                                frame_path: nil, from_alias: false, probable: nil)
  end

  let(:other_ctx) { engine_context(create(:apply)).tap { |context| context.adopt_match!(ashby_match) } }

  before { ctx.adopt_match!(ashby_match) }

  it 'is a throttle stage that always runs and has a localized name' do
    expect(described_class.stage).to eq(:throttle)
    expect(described_class.input_digest(ctx)).to be_nil
    expect(I18n.t('apply.stage.throttle', locale: :uk)).to be_present
  end

  it 'claims a free slot and pushes next_allowed_at one interval ahead' do
    result = run

    expect(result).to be_success
    expect(ApplyHostSlot.find('ashby:preply').next_allowed_at).to be_within(5.seconds).of(10.minutes.from_now)
    expect(result[:step_result]).to eq('host_key' => 'ashby:preply')
  end

  it 'records the apply holding the slot' do
    run

    expect(ApplyHostSlot.find('ashby:preply').holder_apply_id).to eq(apply.id)
  end

  it 'raises Throttled(until: next_allowed_at) while another apply holds the slot, without moving it' do
    first = run
    taken = ApplyHostSlot.find('ashby:preply').next_allowed_at
    expect(first).to be_success

    expect { described_class.call(ctx: other_ctx) }.to raise_error(Apply::Operation::Engine::Throttled) { |error|
      expect(error.until).to be_within(1.second).of(taken)
    }
    expect(ApplyHostSlot.find('ashby:preply')).to have_attributes(next_allowed_at: taken, holder_apply_id: apply.id)
  end

  it "lets the holder's own retry take the slot again (e.g. after PoolBusy or a halt before the claim)" do
    ApplyHostSlot.create!(host_key: 'ashby:preply', next_allowed_at: 8.minutes.from_now, holder_apply_id: apply.id)

    expect(run).to be_success
    expect(ApplyHostSlot.find('ashby:preply').next_allowed_at).to be_within(5.seconds).of(10.minutes.from_now)
  end

  it 'takes the slot again once next_allowed_at has passed' do
    ApplyHostSlot.create!(host_key: 'ashby:preply', next_allowed_at: 1.minute.ago, holder_apply_id: other_ctx.apply.id)

    expect(run).to be_success
    expect(ApplyHostSlot.find('ashby:preply').next_allowed_at).to be > Time.current
  end

  it 'throttles tenants independently' do
    ApplyHostSlot.create!(host_key: 'ashby:other', next_allowed_at: 1.hour.from_now, holder_apply_id: other_ctx.apply.id)

    expect(run).to be_success
  end

  it 'lets exactly one of two concurrent runs (two applies) on one host_key through' do
    outcomes = [ ctx, other_ctx ].map do |run_ctx|
      Thread.new do
        Rails.application.executor.wrap do
          described_class.call(ctx: run_ctx)
          :acquired
        rescue Apply::Operation::Engine::Throttled
          :throttled
        end
      end
    end.map(&:value)

    expect(outcomes).to contain_exactly(:acquired, :throttled)
  end

  it 'skips the throttle for a platform without a key' do
    allow(ctx.platform.class).to receive(:throttle).and_return(interval: 10.minutes, key: ->(_ctx) { nil })

    expect(run).to be_success
    expect(ApplyHostSlot.count).to eq(0)
  end
end
