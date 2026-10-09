# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Engine::ClaimSubmit do
  let(:apply) { create(:apply) }
  let(:ctx) { engine_context(apply) }

  def claim
    described_class.call(ctx:)
  end

  it 'sets submit_claimed_at for the owning run' do
    expect(claim.model).to be(true)
    expect(apply.reload).to be_claimed
  end

  it 'raises already_claimed on a second claim' do
    claim

    expect { claim }.to raise_error(Apply::Operation::Engine::Halt) { |halt| expect(halt.code).to eq(:already_claimed) }
  end

  it 'raises already_claimed once the apply was submitted' do
    ctx
    Apply.where(id: apply.id).update_all(submitted_at: 1.minute.ago)

    expect { claim }.to raise_error(Apply::Operation::Engine::Halt) { |halt| expect(halt.code).to eq(:already_claimed) }
  end

  context 'when another non-cancelled apply of the same user and vacancy holds an open claim' do
    before do
      create(:apply, :claimed, user: apply.user, vacancy: apply.vacancy, user_profile: apply.user_profile,
                               ai_integration: apply.ai_integration, source_profile: apply.source_profile)
    end

    it 'raises already_claimed from the unique index (index_applies_one_open_claim_per_vacancy)' do
      expect { claim }.to raise_error(Apply::Operation::Engine::Halt) { |halt| expect(halt.code).to eq(:already_claimed) }
      expect(apply.reload).not_to be_claimed
    end

    it 'leaves the surrounding transaction usable' do
      expect { claim }.to raise_error(Apply::Operation::Engine::Halt)
      expect(Apply.where(id: apply.id).count).to eq(1)
    end
  end

  it 'does not count a cancelled apply holding a claim' do
    create(:apply, :claimed, state: :cancelled, user: apply.user, vacancy: apply.vacancy,
                             user_profile: apply.user_profile, ai_integration: apply.ai_integration,
                             source_profile: apply.source_profile)

    expect(claim.model).to be(true)
  end

  it 'raises Fenced for a zombie run' do
    ctx
    rotate_run_token!(apply)

    expect { claim }.to raise_error(Apply::Operation::Engine::Fenced)
    expect(apply.reload).not_to be_claimed
  end
end
