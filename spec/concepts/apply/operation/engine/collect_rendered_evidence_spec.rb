# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Engine::CollectRenderedEvidence do
  let(:frame) { 'https://jobs.ashbyhq.com/preply/20587adf-cf02-473e-8a80-7b009711a2cf?embed=js' }
  let(:snapshot) do
    ApplyMate::Client::Browser::Snapshot.new(
      frames: [], elements: [], digest: '',
      evidence: { frame_urls: [ 'https://preply.com/en/careers/apply', frame ], script_srcs: [ 'https://x/embed' ],
                  iframe_srcs: [ frame ], dom_markers: { '.ashby-application-form-field-entry' => 15 } }
    )
  end
  let(:session) { FakeSession.new(html: '', final_url: frame, snapshot:) }

  it "turns every frame's snapshot into current URLs, sources and marker counts" do
    evidence = described_class.call(session:).model

    expect(evidence).to have_attributes(current_urls: [ 'https://preply.com/en/careers/apply', frame ],
                                        iframe_srcs: [ frame ], script_srcs: [ 'https://x/embed' ],
                                        dom_markers: { '.ashby-application-form-field-entry' => 15 }, hops: [])
  end

  it "asks the session for the registry's DOM markers" do
    described_class.call(session:)

    expect(session.calls).to include([ :snapshot_all, { markers: Apply::Platform::Registry.dom_markers } ])
  end

  it 'reuses a snapshot the caller already took' do
    described_class.call(session:, snapshot:)

    expect(session.calls_of(:snapshot_all)).to be_empty
  end
end
