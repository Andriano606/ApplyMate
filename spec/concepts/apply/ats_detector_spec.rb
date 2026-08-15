# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::AtsDetector do
  describe '.call with host rules' do
    {
      'https://boards.greenhouse.io/acme/jobs/123'          => 'greenhouse',
      'https://job-boards.greenhouse.io/acme/jobs/123'      => 'greenhouse',
      'https://jobs.lever.co/acme/6c85-4f9b'                => 'lever',
      'https://apply.workable.com/acme/j/ABC123/'           => 'workable',
      'https://acme.recruitee.com/o/senior-dev'             => 'recruitee',
      'https://jobs.smartrecruiters.com/Acme/744000'        => 'smartrecruiters',
      'https://jobs.ashbyhq.com/acme/uuid'                  => 'ashby',
      'https://acme.teamtailor.com/jobs/123'                => 'teamtailor',
      'https://acme.bamboohr.com/careers/33'                => 'bamboohr',
      'https://acme.breezy.hr/p/slug'                       => 'breezy',
      'https://join.com/companies/acme/123'                 => 'join',
      'https://acme.wd3.myworkdayjobs.com/en-US/ext/job/x'  => 'workday'
    }.each do |url, expected|
      it "detects #{expected} from #{url}" do
        expect(described_class.call(url:)).to eq(expected)
      end
    end

    it 'returns nil for self-hosted pages' do
      expect(described_class.call(url: 'https://careers.acme.com/apply')).to be_nil
      expect(described_class.call(url: 'https://acme.peopleforce.io/careers/v/1')).to be_nil
    end

    it 'tolerates garbage URLs' do
      expect(described_class.call(url: 'not a url::')).to be_nil
      expect(described_class.call(url: nil)).to be_nil
    end
  end

  describe '.call with HTML fallback' do
    it 'detects a Greenhouse embed on an employer page' do
      html = '<script src="https://boards.greenhouse.io/embed/job_board/js?for=acme"></script>'
      expect(described_class.call(url: 'https://careers.acme.com', html:)).to eq('greenhouse')
    end

    it 'detects a Lever embed by class prefix' do
      html = '<div class="lever-job-title">Dev</div>'
      expect(described_class.call(url: 'https://careers.acme.com', html:)).to eq('lever')
    end

    it 'prefers the host rule over HTML markers' do
      html = '<script src="whr.js"></script>'
      expect(described_class.call(url: 'https://jobs.lever.co/acme/1', html:)).to eq('lever')
    end

    it 'returns nil when nothing matches' do
      expect(described_class.call(url: 'https://careers.acme.com', html: '<form></form>')).to be_nil
    end
  end
end
