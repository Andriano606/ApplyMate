# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::ExternalAts::Greenhouse do
  include_context 'honeytech dou'

  let(:adapter)  { described_class.new }
  let(:gh_url)   { 'https://boards.greenhouse.io/acme/jobs/4045807008' }
  let(:job_json) { File.read(Rails.root.join('spec/fixtures/files/ats/greenhouse_job.json')) }

  before do
    apply.update!(resolved_url: gh_url, ats: 'greenhouse')

    allow_any_instance_of(ApplyMate::Client::AsyncHttp).to receive(:get)
      .with('https://boards-api.greenhouse.io/v1/boards/acme/jobs/4045807008?questions=true', any_args)
      .and_return(ApplyMate::Client::AsyncHttp::Response.new(job_json, {}, 200, nil))
  end

  describe '#fetch_fields' do
    subject(:fields) { adapter.fetch_fields(apply:) }

    it 'builds the field IR with pre-filled canonical roles' do
      roles = fields.index_by { |f| f['name'] }.transform_values { |f| f['role'] }
      expect(roles['first_name']).to eq('first_name')
      expect(roles['email']).to eq('email')
      expect(roles['resume']).to eq('cv_file')
      expect(roles['cover_letter']).to eq('cover_letter')
      expect(roles['job_application[answers_attributes][0][text_value]']).to eq('custom_question')
    end

    it 'carries labels, required flags, options and fingerprints' do
      select = fields.find { |f| f['type'] == 'select' }
      expect(select['options']).to include('label' => 'Yes', 'value' => '1')
      expect(select['required']).to be(true)
      expect(fields.map { |f| f['fingerprint'] }).to all(match(/\A[0-9a-f]{40}\z/))
      expect(fields.find { |f| f['name'] == 'resume' }['type']).to eq('file')
    end

    it 'raises AdapterError on an unrecognized URL' do
      apply.update!(resolved_url: 'https://boards.greenhouse.io/acme/careers')
      expect { fields }.to raise_error(Apply::ExternalAts::Base::AdapterError, /unrecognized/)
    end

    it 'raises AdapterError when the API answers with an error' do
      allow_any_instance_of(ApplyMate::Client::AsyncHttp).to receive(:get)
        .and_return(ApplyMate::Client::AsyncHttp::Response.new('not found', {}, 404, nil))
      expect { fields }.to raise_error(Apply::ExternalAts::Base::AdapterError, /HTTP 404/)
    end

    it 'parses embed URLs with for/token params' do
      apply.update!(resolved_url: 'https://boards.greenhouse.io/embed/job_app?for=acme&token=4045807008')
      expect(fields).to be_present
    end
  end

  describe '#submit' do
    let(:handler) { Apply::Handler::Dou.new(apply:) }

    before do
      apply.update!(filled_inputs: [
        { 'name' => 'first_name', 'type' => 'text', 'value' => 'Jane' },
        { 'name' => 'email', 'type' => 'text', 'value' => 'dev@example.com' }
      ])
    end

    it 'posts multipart to the board application endpoint and accepts a redirect' do
      expect_any_instance_of(ApplyMate::Client::AsyncHttp).to receive(:post_multipart)
        .with('https://boards.greenhouse.io/acme/jobs/4045807008',
              hash_including(payload: hash_including('first_name' => 'Jane')))
        .and_return(ApplyMate::Client::AsyncHttp::Response.new('', {}, 302, nil))

      adapter.submit(apply:, handler:)
    end

    it 'raises AdapterError on a rejected submission' do
      allow_any_instance_of(ApplyMate::Client::AsyncHttp).to receive(:post_multipart)
        .and_return(ApplyMate::Client::AsyncHttp::Response.new('captcha required', {}, 422, nil))

      expect { adapter.submit(apply:, handler:) }
        .to raise_error(Apply::ExternalAts::Base::AdapterError, /HTTP 422/)
    end
  end
end
