# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ApplyHostSlot do
  it 'is keyed by host_key' do
    slot = described_class.create!(host_key: 'ashby:preply', next_allowed_at: 10.minutes.from_now, holder_apply_id: 1)

    expect(described_class.find('ashby:preply')).to eq(slot)
    expect(described_class.primary_key).to eq('host_key')
  end

  it 'rejects a second row for the same host_key' do
    described_class.create!(host_key: 'host:a', next_allowed_at: 1.minute.from_now, holder_apply_id: 1)

    expect { described_class.create!(host_key: 'host:a', next_allowed_at: 2.minutes.from_now, holder_apply_id: 2) }
      .to raise_error(ActiveRecord::RecordNotUnique)
  end
end
