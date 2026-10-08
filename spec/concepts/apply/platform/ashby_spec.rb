# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Platform::Ashby do
  let(:jid) { '20587adf-cf02-473e-8a80-7b009711a2cf' }
  let(:preply) { "https://preply.com/en/careers/apply?ashby_jid=#{jid}" }
  let(:frame) { "https://jobs.ashbyhq.com/preply/#{jid}?embed=js" }
  let(:posting_json) { file_fixture('apply_engine/ashby/api_job_posting.json').read }

  def evidence(**attrs)
    Apply::Operation::Engine::Detect::Evidence.build(**attrs)
  end

  # One styled radio of the same question from two page loads: the id / name carry a fresh instance UUID each time.
  def radio(instance)
    path = "#{instance}_ab315a8b-7c2d-4e9f-8a1b-5c6d7e8f9a06"
    Apply::Platform::Base::RawField.new(element: { 'attrs' => { 'name' => path, 'data-field-path' => nil } },
                                        default_key: "f_#{instance}")
  end

  it_behaves_like 'a platform adapter' do
    let(:positive_evidence) { evidence(current_urls: [ preply, frame ], iframe_srcs: [ frame ]) }
    let(:negative_evidence) do
      evidence(current_urls: [ 'https://jobs.ashbyhq.com/preply', 'https://www.ashbyhq.com/customers' ],
               hops: [ frame ])
    end
    let(:expected_captures) { { 'slug' => 'preply', 'jid' => jid } }
    let(:expected_canonical_form_url) { "https://jobs.ashbyhq.com/preply/#{jid}/application" }
    let(:schema_response) { ApplyMate::Client::Response.new(posting_json, {}, 200, nil) }
    let(:expected_schema_size) { 15 }
    let(:field_key_renders) do
      [ radio('2e4a9c2a-1111-4222-8333-444455556666'), radio('3314609c-aaaa-4bbb-8ccc-ddddeeeeffff') ]
    end
  end

  describe 'adapter' do
    let(:ctx) { engine_context(create(:apply)) }
    let(:detected) do
      Apply::Operation::Engine::Detect.call(evidence: evidence(current_urls: [ preply, frame ], iframe_srcs: [ frame ]))
                                      .model
    end
    let(:adapter) do
      ctx.adopt_match!(detected)
      ctx.platform
    end

    it 'keys the posting for cross-board duplicates' do
      expect(adapter.apply_key).to eq("ashby:preply:#{jid}")
    end

    it 'prefers the field root data-field-path and strips the instance prefix' do
      raw = Apply::Platform::Base::RawField.new(
        element: { 'attrs' => { 'name' => 'Acknowledge/Confirm',
                                'data-field-path' => "f1334a1e-0000-4000-8000-000000000000_#{jid}" } },
        default_key: 'f_x'
      )

      expect(adapter.field_key(raw)).to eq("ashby:#{jid}")
    end

    it 'falls back to the default key for a control without path or name' do
      raw = Apply::Platform::Base::RawField.new(element: { 'attrs' => {} }, default_key: 'f_abc_0')

      expect(adapter.field_key(raw)).to eq('f_abc_0')
    end

    it 'fills files first' do
      text = instance_double(Apply::Field, file?: false)
      file = instance_double(Apply::Field, file?: true)

      expect(adapter.fill_order([ text, file ])).to eq([ file, text ])
    end

    it 'waits for the schema keys inside the form root once the schema is known' do
      expect(adapter.readiness).to be_nil

      ctx.schema = [ instance_double(Apply::Field, id: "ashby:#{jid}") ]

      expect(adapter.readiness).to have_attributes(kind: :schema_keys, keys: [ jid ], attr: 'data-field-path',
                                                   ratio: 0.8, root: '#form[role="tabpanel"]',
                                                   key_prefix: described_class::INSTANCE_PREFIX_SOURCE)
    end

    # field_key (Ruby) and readiness.js (JS, via key_prefix) strip the per-render prefix from ONE regex source.
    it 'strips the instance prefix in field_key with the same source readiness passes to the probe' do
      instance = '0b1c2d3e-4f50-4a6b-8c7d-9e0f1a2b3c4d'
      element = { 'attrs' => { 'name' => "#{instance.upcase}_question-1" } }
      raw = Apply::Platform::Base::RawField.new(element:, default_key: 'x')

      expect(adapter.field_key(raw)).to eq('ashby:question-1')
      expect(described_class::INSTANCE_PREFIX.source).to include(described_class::INSTANCE_PREFIX_SOURCE)
    end

    it 'excludes the autofill pane' do
      expect(adapter.excluded_regions).to eq([ '.ashby-application-form-autofill-input-root' ])
    end

    it 'throttles submits per Ashby tenant' do
      adapter

      expect(described_class.throttle).to include(interval: 10.minutes)
      expect(described_class.throttle[:key].call(ctx)).to eq('ashby:preply')
    end

    it 'needs two success signals and accepts only an error-free submit response' do
      success = adapter.success_evidence
      body_ok = success.dig(:submit_request, :body_ok)

      expect(success[:min_signals]).to eq(2)
      expect(success.dig(:submit_request, :url)).to match('https://jobs.ashbyhq.com/api/non-user-graphql?op=Submit')
      expect(body_ok.call('data' => { 'submit' => { 'success' => true } })).to be(true)
      expect(body_ok.call('data' => nil, 'errors' => [ { 'message' => 'invalid' } ])).to be(false)
      expect(success[:texts]).to include(match('Thank you for applying'))
    end

    it 'traces an unavailable schema and returns nil (the DOM is read instead)' do
      allow(ApplyMate::Net::Operation::ResolvePublicAddress).to receive(:call) { |url:| FixtureSite.resolution(url) }
      allow(ctx.http).to receive(:post).and_return(ApplyMate::Client::Response.new('oops', {}, 502, nil))

      expect(adapter.fetch_schema).to be_nil
      expect(ctx.scratch.trace.last).to include('event' => 'schema_unavailable', 'platform' => 'ashby')
    end

    it 'posts the schema read to the origin with the slug and posting id' do
      allow(ApplyMate::Net::Operation::ResolvePublicAddress).to receive(:call) { |url:| FixtureSite.resolution(url) }
      allow(ctx.http).to receive(:post).and_return(ApplyMate::Client::Response.new(posting_json, {}, 200, nil))

      adapter.fetch_schema

      expect(ctx.http).to have_received(:post).with(
        'https://jobs.ashbyhq.com/api/non-user-graphql?op=ApiJobPosting',
        body: satisfy { |body| JSON.parse(body)['variables'] == { 'organizationHostedJobsPageName' => 'preply', 'jobPostingId' => jid } },
        headers: hash_including('Content-Type' => 'application/json'), resolve: anything
      )
    end
  end

  describe 'origin seam' do
    let(:fixture_ashby) do
      Class.new(described_class) do
        def self.origin
          'http://host.docker.internal:4567/ashby'
        end

        def self.key
          'ashby'
        end

        declare_signals!
      end
    end

    it 'builds every pattern from the origin, so a subclass can point at FixtureSite' do
      url = "http://host.docker.internal:4567/ashby/preply/#{'1' * 8}-1111-4111-8111-#{'1' * 12}/application"

      expect(fixture_ashby.job_url.match(url)[:slug]).to eq('preply')
      expect(fixture_ashby.graphql_url).to match('http://host.docker.internal:4567/ashby/api/non-user-graphql?op=X')
      expect(fixture_ashby.signals.find { |signal| signal.kind == :host }.pattern).to match('host.docker.internal')
      expect(described_class.job_url).not_to match(url)
    end

    it 'keeps the declarations of Ashby but only its own signals' do
      expect(fixture_ashby.required_captures).to eq(%i[slug jid])
      expect(fixture_ashby.throttle).to eq(described_class.throttle)
      expect(fixture_ashby.signals.size).to eq(described_class.signals.size)
    end
  end
end
