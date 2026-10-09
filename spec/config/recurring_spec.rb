# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'config/recurring.yml' do
  let(:schedule) { YAML.load_file(Rails.root.join('config/recurring.yml')) }

  {
    'reap_stale_applies' => [ 'Apply::Job::ReapStale', 'every minute' ],
    'expire_waiting_applies' => [ 'Apply::Job::ExpireWaiting', 'every hour at minute 7' ],
    'prune_apply_steps' => [ 'Apply::Job::PruneApplySteps', 'every day at 4am' ]
  }.each do |key, (klass, cron)|
    it "schedules #{klass} #{cron} on the default queue" do
      entry = schedule.fetch(key)

      expect(entry['class']).to eq(klass)
      expect(entry['schedule']).to eq(cron)
      expect(klass.constantize.new.queue_name).to eq('default')
      expect(SolidQueue::RecurringTask.from_configuration(key, **entry.symbolize_keys)).to be_valid
    end
  end
end
