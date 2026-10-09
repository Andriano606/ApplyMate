# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Engine::FencedUpdate do
  let(:apply) { create(:apply) }
  let(:ctx) { engine_context(apply) }

  def update(attributes, **)
    described_class.call(ctx:, attributes:, **)
  end

  it 'writes the attributes for the owning run' do
    expect(update({ stage: 'fake_prepare' }).model).to eq(1)
    expect(apply.reload.stage).to eq('fake_prepare')
  end

  it 'touches users.applies_changed_at only when the state changes' do
    ctx
    expect { update({ stage: 'fake_prepare' }) }.not_to(change { apply.user.reload.applies_changed_at })
    expect { update({ state: Apply.states[:failed] }) }.to(change { apply.user.reload.applies_changed_at })
  end

  context 'when another run rotated the token (zombie)' do
    before do
      ctx
      rotate_run_token!(apply)
    end

    it 'writes nothing, fences the context and raises Fenced' do
      expect { update({ stage: 'zombie' }) }.to raise_error(Apply::Operation::Engine::Fenced)
      expect(apply.reload.stage).to be_nil
      expect(ctx).to be_fenced
    end

    it 'raises Fenced even when only the extra condition was given' do
      expect { update({ stage: 'zombie' }, extra_condition: 'submit_claimed_at IS NULL') }
        .to raise_error(Apply::Operation::Engine::Fenced)
    end
  end

  it 'raises Fenced without a query once the context is fenced' do
    ctx.fence!

    expect { update({ stage: 'late' }) }.to raise_error(Apply::Operation::Engine::Fenced)
    expect(apply.reload.stage).to be_nil
  end

  it 'returns 0 without fencing when only the extra condition failed' do
    result = update({ stage: 'x' }, extra_condition: 'submit_claimed_at IS NOT NULL')

    expect(result.model).to eq(0)
    expect(ctx).not_to be_fenced
    expect(apply.reload.stage).to be_nil
  end
end
