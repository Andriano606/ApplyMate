# frozen_string_literal: true

require 'rails_helper'

# Lighter coverage for the non-Greenhouse adapters: URL parsing, happy-path
# field IR, and AdapterError on API failure. Greenhouse has its own full spec.
RSpec.describe 'ATS adapters' do
  include_context 'honeytech dou'

  def http_response(body, status: 200)
    ApplyMate::Client::AsyncHttp::Response.new(body, {}, status, nil)
  end

  describe Apply::ExternalAts::Lever do
    let(:adapter) { described_class.new }
    let(:url)     { 'https://jobs.lever.co/acme/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' }

    before { apply.update!(resolved_url: url, ats: 'lever') }

    it 'returns the standard Lever field set after validating the posting' do
      allow_any_instance_of(ApplyMate::Client::AsyncHttp).to receive(:get)
        .and_return(http_response({ id: 'aaaa', applyUrl: "#{url}/apply" }.to_json))

      fields = adapter.fetch_fields(apply:)
      roles  = fields.index_by { |f| f['name'] }.transform_values { |f| f['role'] }
      expect(roles).to include('name' => 'full_name', 'email' => 'email',
                               'comments' => 'cover_letter', 'resume' => 'cv_file')
      expect(fields.map { |f| f['fingerprint'] }).to all(be_present)
    end

    it 'raises AdapterError on a non-Lever URL' do
      apply.update!(resolved_url: 'https://jobs.lever.co/acme/not-a-uuid')
      expect { adapter.fetch_fields(apply:) }
        .to raise_error(Apply::ExternalAts::Base::AdapterError, /unrecognized/)
    end
  end

  describe Apply::ExternalAts::Workable do
    let(:adapter) { described_class.new }
    let(:url)     { 'https://apply.workable.com/acme/j/ABC123/' }

    before { apply.update!(resolved_url: url, ats: 'workable') }

    it 'maps the form API payload to IR with roles' do
      form = {
        fields: [
          { key: 'firstname', label: 'First name', type: 'string', required: true },
          { key: 'email', label: 'Email', type: 'string', required: true },
          { key: 'resume', label: 'Resume', type: 'file', required: true }
        ],
        questions: [
          { id: 'q1', body: 'Why Acme?', type: 'free_text', required: false },
          { id: 'q2', body: 'Seniority', type: 'multiple_choice',
            options: [ { id: 'o1', body: 'Senior' }, { id: 'o2', body: 'Middle' } ] }
        ]
      }.to_json
      allow_any_instance_of(ApplyMate::Client::AsyncHttp).to receive(:get)
        .with('https://apply.workable.com/api/v1/accounts/acme/jobs/ABC123/form', any_args)
        .and_return(http_response(form))

      fields = adapter.fetch_fields(apply:)
      roles  = fields.index_by { |f| f['name'] }.transform_values { |f| f['role'] }
      expect(roles).to include('firstname' => 'first_name', 'email' => 'email',
                               'resume' => 'cv_file', 'q1' => 'custom_question')
      expect(fields.find { |f| f['name'] == 'q2' }['options'])
        .to include('label' => 'Senior', 'value' => 'o1')
    end

    it 'raises AdapterError when the payload has no fields' do
      allow_any_instance_of(ApplyMate::Client::AsyncHttp).to receive(:get)
        .and_return(http_response({}.to_json))
      expect { adapter.fetch_fields(apply:) }
        .to raise_error(Apply::ExternalAts::Base::AdapterError, /no fields/)
    end
  end

  describe Apply::ExternalAts::Recruitee do
    let(:adapter) { described_class.new }
    let(:url)     { 'https://acme.recruitee.com/o/senior-ruby' }

    before { apply.update!(resolved_url: url, ats: 'recruitee') }

    it 'returns standard fields plus open questions' do
      offer = {
        offer: {
          title: 'Senior Ruby', slug: 'senior-ruby',
          open_questions: [ { body: 'Expected salary?', required: true } ]
        }
      }.to_json
      allow_any_instance_of(ApplyMate::Client::AsyncHttp).to receive(:get)
        .with('https://acme.recruitee.com/api/offers/senior-ruby', any_args)
        .and_return(http_response(offer))

      fields = adapter.fetch_fields(apply:)
      expect(fields.map { |f| f['role'] }).to include('full_name', 'email', 'cv_file', 'custom_question')
      question = fields.find { |f| f['role'] == 'custom_question' }
      expect(question['label']).to eq('Expected salary?')
      expect(question['name']).to include('open_question_answers_attributes')
    end

    it 'raises AdapterError on a non-Recruitee URL' do
      apply.update!(resolved_url: 'https://careers.acme.com/o/dev')
      expect { adapter.fetch_fields(apply:) }
        .to raise_error(Apply::ExternalAts::Base::AdapterError, /unrecognized/)
    end
  end
end
