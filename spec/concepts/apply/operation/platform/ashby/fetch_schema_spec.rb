# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Platform::Ashby::FetchSchema do
  subject(:fields) { described_class.call(slug: 'preply', jid:, http:, origin: 'https://jobs.ashbyhq.com').model }

  let(:http) { ApplyMate::Client::ImpersonateHttp.new }
  let(:jid) { '20587adf-cf02-473e-8a80-7b009711a2cf' }
  let(:posting_json) { file_fixture('apply_engine/ashby/api_job_posting.json').read }
  let(:response) { ApplyMate::Client::Response.new(posting_json, {}, 200, nil) }
  let(:by_label) { fields.index_by(&:label) }

  before do
    allow(ApplyMate::Net::Operation::ResolvePublicAddress).to receive(:call) { |url:| FixtureSite.resolution(url) }
    allow(http).to receive(:post) { response }
  end

  it 'maps every field entry once to a schema_api Apply::Field keyed by its path' do
    expect(fields.size).to eq(15)
    expect(fields).to all(be_a(Apply::Field).and(have_attributes(source: 'schema_api', semantic: nil, target: nil)))
    expect(fields.map(&:id)).to include('ashby:_systemfield_name', 'ashby:_systemfield_resume',
                                        'ashby:9f2c7a14-5e3b-4d6a-8c1f-0a2b3c4d5e04')
    expect(fields.map(&:id).uniq.size).to eq(15)
  end

  it 'maps the Ashby types to field kinds' do
    expect(fields.map(&:kind)).to eq(%w[
      text email tel file text text combobox text radio_group number text textarea radio_group checkbox_group
      checkbox_group
    ])
  end

  it 'renders a 15-option ValueSelect as a combobox and a 3-option one as radios' do
    expect(by_label['How did you get to know Preply?']).to have_attributes(kind: 'combobox', required: true)
    expect(by_label['How did you get to know Preply?'].options.size).to eq(15)
    expect(by_label['How many years have you managed support agents?']).to have_attributes(kind: 'radio_group')
    expect(by_label['How many years have you managed support agents?'].options.size).to eq(3)
  end

  it 'gives a Boolean question Yes / No options' do
    expect(by_label['Are you open to working in shifts?'].options.pluck('label')).to eq(%w[Yes No])
  end

  it 'reads required, multiple and the stripped description' do
    expect(by_label['Linkedin profile URL']).to have_attributes(required: false)
    expect(by_label['Privacy notice']).to have_attributes(multiple: true, required: true)
    expect(fields.map(&:description).compact).to all(satisfy { |text| !text.include?('<') })
  end

  it 'posts the persisted query through the guarded, pinned fetch' do
    fields

    expect(ApplyMate::Net::Operation::ResolvePublicAddress).to have_received(:call)
      .with(url: 'https://jobs.ashbyhq.com/api/non-user-graphql?op=ApiJobPosting')
    expect(http).to have_received(:post).with(
      'https://jobs.ashbyhq.com/api/non-user-graphql?op=ApiJobPosting',
      body: satisfy do |body|
        json = JSON.parse(body)
        json['operationName'] == 'ApiJobPosting' && json['query'].include?('applicationForm') &&
          json['variables'] == { 'organizationHostedJobsPageName' => 'preply', 'jobPostingId' => jid }
      end,
      headers: hash_including('Content-Type' => 'application/json'), resolve: anything
    )
  end

  describe 'an unusable answer raises SchemaUnavailable' do
    {
      'a non-2xx status' => [ '{"data":{}}', 503 ],
      'invalid JSON' => [ '<html>blocked</html>', 200 ],
      'GraphQL errors' => [ '{"errors":[{"message":"not found"}],"data":null}', 200 ],
      'no posting' => [ '{"data":{"jobPosting":null}}', 200 ],
      'a form without entries' => [ '{"data":{"jobPosting":{"applicationForm":{"sections":[]}}}}', 200 ]
    }.each do |name, (body, status)|
      it name do
        allow(http).to receive(:post).and_return(ApplyMate::Client::Response.new(body, {}, status, nil))

        expect { fields }.to raise_error(Apply::Platform::SchemaUnavailable, /ashby ApiJobPosting/)
      end
    end

    it 'a failed request' do
      allow(http).to receive(:post).and_raise(ApplyMate::Client::ImpersonateHttp::RequestError, 'timeout')

      expect { fields }.to raise_error(Apply::Platform::SchemaUnavailable, /request failed/)
    end
  end

  it 'lets an unsafe address through as UnsafeUrlError, before any request' do
    allow(ApplyMate::Net::Operation::ResolvePublicAddress).to receive(:call)
      .and_raise(ApplyMate::Net::UnsafeUrlError.new(:private, url: 'https://jobs.ashbyhq.com'))

    expect { fields }.to raise_error(ApplyMate::Net::UnsafeUrlError)
    expect(http).not_to have_received(:post)
  end
end
