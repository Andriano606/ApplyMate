# frozen_string_literal: true

# The contract every Apply::Platform adapter honours (.ai/docs/apply_engine.md, "Як додати нову платформу").
#
#   it_behaves_like 'a platform adapter' do
#     let(:positive_evidence) { Apply::Operation::Engine::Detect::Evidence.build(current_urls: [...]) }
#     let(:negative_evidence) { ... }                    # a near miss: must stay generic
#     let(:expected_captures) { { 'slug' => 'x', ... } } # from positive_evidence
#     let(:expected_canonical_form_url) { 'https://...' } # or nil when the platform has none
#     let(:schema_response) { ApplyMate::Client::Response.new(json, {}, 200, url) } # or nil without fetch_schema
#     let(:expected_schema_size) { 15 }
#     let(:field_key_renders) { [raw_from_render_1, raw_from_render_2] } # RawFields of ONE field, two renders
#   end
#
# described_class is the adapter. Schema reads go through GuardedFetch with the address guard stubbed and the run's
# ImpersonateHttp (ctx.http) answering `schema_response` for any POST / GET.
RSpec.shared_examples 'a platform adapter' do
  let(:adapter_ctx) { engine_context(create(:apply)) }
  let(:detected) { Apply::Operation::Engine::Detect.call(evidence: positive_evidence).model }
  let(:adapter) do
    adapter_ctx.adopt_match!(detected)
    adapter_ctx.platform
  end

  before do
    allow(ApplyMate::Net::Operation::ResolvePublicAddress).to receive(:call) { |url:| FixtureSite.resolution(url) }
    if schema_response
      allow(adapter_ctx.http).to receive_messages(post: schema_response, get: schema_response)
    end
  end

  it 'is listed in the registry' do
    expect(Apply::Platform::Registry.platforms).to include(described_class)
  end

  it 'is detected from its positive evidence with the captures it needs' do
    expect(detected).to have_attributes(key: described_class.key)
    expect(detected.confidence).to be >= Apply::Platform::Registry::THRESHOLD
    expect(detected.captures).to include(expected_captures)
  end

  it 'is not detected from the negative evidence' do
    expect(Apply::Operation::Engine::Detect.call(evidence: negative_evidence).model).to be_generic
  end

  it 'builds the canonical form URL from the captures' do
    expect(adapter.canonical_form_url).to eq(expected_canonical_form_url)
  end

  it 'parses its schema into Apply::Fields whose ids are field keys' do
    skip 'no fetch_schema' if schema_response.nil?

    schema = adapter.fetch_schema

    expect(schema.size).to eq(expected_schema_size)
    expect(schema).to all(be_a(Apply::Field).and(have_attributes(source: 'schema_api')))
    expect(schema.map(&:id)).to all(start_with("#{described_class.key}:"))
    expect(schema.map(&:id).uniq.size).to eq(schema.size)
    expect(schema.map(&:kind)).to all(be_in(Apply::Field::KINDS))
  end

  it 'gives one field the same key across two renders' do
    first, second = field_key_renders

    expect(adapter.field_key(first)).to eq(adapter.field_key(second))
    expect(adapter.field_key(first)).to start_with("#{described_class.key}:")
  end

  it 'describes success with positive evidence only' do
    evidence = adapter.success_evidence

    expect(evidence.keys).to include(:texts, :url_patterns, :submit_request, :min_signals)
    expect(evidence.keys - %i[texts url_patterns submit_request min_signals]).to all(be_in(%i[selectors failure_selectors]))
    expect(evidence[:texts] + evidence[:url_patterns]).to all(be_a(Regexp))
    expect(Array(evidence[:selectors]) + Array(evidence[:failure_selectors])).to all(be_a(String))
    expect(evidence[:min_signals]).to be_between(1, 3)
    expect(evidence[:submit_request]).to include(url: a_kind_of(Regexp), body_ok: a_kind_of(Proc)) if evidence[:submit_request]
  end

  it 'has a throttle key for the tenant' do
    expect(described_class.throttle[:interval]).to be_positive
    expect(described_class.throttle[:key].call(adapter_ctx.tap { adapter })).to be_present
  end
end
