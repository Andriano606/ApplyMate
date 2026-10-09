# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'config/initializers/browserd_leases.rb' do
  let(:hook) do
    SolidQueue::Supervisor.lifecycle_hooks[:start].find do |block|
      block.source_location&.first&.end_with?('config/initializers/browserd_leases.rb')
    end
  end

  before { allow(ApplyMate::Client::Browser::Operation::ReleaseOrphanLeases).to receive(:call) }

  it 'registers one Solid Queue start hook' do
    expect(hook).to be_present
  end

  %w[apply all].each do |role|
    it "releases this host's orphan leases for SQ_ROLE=#{role}" do
      allow(Apply::Operation::AssertQueueTopology).to receive(:role).and_return(role)

      hook.call(instance_double(SolidQueue::Supervisor))

      expect(ApplyMate::Client::Browser::Operation::ReleaseOrphanLeases)
        .to have_received(:call).with(owner_prefix: "#{Socket.gethostname}:#{Rails.root.basename}:test:")
    end
  end

  it 'never touches browserd for the general worker' do
    allow(Apply::Operation::AssertQueueTopology).to receive(:role).and_return('general')

    hook.call(instance_double(SolidQueue::Supervisor))

    expect(ApplyMate::Client::Browser::Operation::ReleaseOrphanLeases).not_to have_received(:call)
  end
end
