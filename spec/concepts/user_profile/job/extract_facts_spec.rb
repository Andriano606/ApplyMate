# frozen_string_literal: true

require 'rails_helper'

RSpec.describe UserProfile::Job::ExtractFacts, type: :job do
  it 'runs on the apply queue' do
    expect(described_class.new(9).queue_name).to eq('apply')
  end

  it 'limits concurrency to one run per UserProfile for 10 minutes' do
    job = described_class.new(9)

    expect(job.concurrency_key).to eq('UserProfile::Job::ExtractFacts/user_profile_facts:9')
    expect(job.concurrency_limit).to eq(1)
    expect(job.concurrency_duration).to eq(10.minutes)
  end

  it 'retries a transient AI failure, then ends (the next apply extracts inline)' do
    user_profile = create(:user_profile)
    allow(UserProfile::Operation::ExtractFacts).to receive(:call).and_raise(ApplyMate::Ai::Client::Base::EmptyResponse)

    expect { described_class.perform_now(user_profile.id) }.to have_enqueued_job(described_class).with(user_profile.id)
  end

  it 'runs the ExtractFacts operation' do
    user_profile = create(:user_profile)
    allow(UserProfile::Operation::ExtractFacts).to receive(:call)

    described_class.perform_now(user_profile.id)

    expect(UserProfile::Operation::ExtractFacts).to have_received(:call).with(user_profile:)
  end

  describe 'enqueueing from the profile operations' do
    let(:current_user) { create(:user) }

    def params_for(attrs)
      ActionController::Parameters.new(user_profile: attrs)
    end

    it 'enqueues on Create' do
      expect { UserProfile::Operation::Create.call(params: params_for(name: 'P', cv: 'CV'), current_user:) }
        .to have_enqueued_job(described_class).on_queue('apply')
    end

    it 'enqueues on Update only when the cv changed' do
      profile = create(:user_profile, user: current_user)

      expect { UserProfile::Operation::Update.call(params: params_for(name: 'Renamed').merge(id: profile.id), current_user:) }
        .not_to have_enqueued_job(described_class)
      expect { UserProfile::Operation::Update.call(params: params_for(cv: 'Other CV').merge(id: profile.id), current_user:) }
        .to have_enqueued_job(described_class).with(profile.id)
    end
  end
end
