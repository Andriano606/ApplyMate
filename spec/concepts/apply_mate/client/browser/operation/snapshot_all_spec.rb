# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ApplyMate::Client::Browser::Operation::SnapshotAll do
  # Canned Driver#evaluate_all_frames result: the top page, the Ashby embed iframe (has an id), a nested iframe
  # without an id, a frame that could not be evaluated, and a frame whose parent is beyond MAX_FRAMES.
  let(:frames) do
    [
      frame(0, 'https://preply.com/en/careers/apply', parent: nil, elements: [ accept_button ],
                                                      scripts: [ 'https://jobs.ashbyhq.com/preply/embed?version=2' ],
                                                      iframes: [ 'https://jobs.ashbyhq.com/preply/jid?embed=js' ],
                                                      markers: { '.ashby-application-form-field-entry' => 0 }),
      frame(1, 'https://jobs.ashbyhq.com/preply/jid/application', parent: 0, element_id: 'ashby_embed_iframe',
                                                                  elements: [ name_input, resume_input ],
                                                                  markers: { '.ashby-application-form-field-entry' => 15 }),
      frame(2, 'https://jobs.ashbyhq.com/widget', parent: 1, element_id: nil, elements: [ hidden_combobox ]),
      { index: 3, url: 'about:blank', name: '', parent_index: 0, element_id: 'ad:slot', value: nil },
      { index: 4, url: 'https://ads.example/slot', name: '', parent_index: nil, element_id: 'slot', value: nil }
    ]
  end
  let(:driver) { instance_double(ApplyMate::Client::Browser::Driver::Playwright, evaluate_all_frames: frames) }
  let(:markers) { [ '.ashby-application-form-field-entry' ] }
  let(:accept_button) { probe_element(0, 'button', 'Accept necessary only', type: nil, strategies: [ { 'css' => 'b' } ]) }
  let(:name_input) { probe_element(0, 'textbox', 'Full Name', root: [ { 'attr' => { 'data-field-path' => 'n' } } ]) }
  let(:resume_input) do
    probe_element(1, nil, 'Resume', type: 'file', self_visible: false, root: [ { 'css' => 'div.dropzone' } ])
  end
  let(:hidden_combobox) do
    probe_element(0, 'combobox', 'Country', self_visible: false, readonly: true, root: [ { 'css' => 'div.select' } ])
  end

  def frame(index, url, parent:, elements:, element_id: nil, scripts: [], iframes: [], markers: {})
    snapshot = { 'frame' => { 'url' => url, 'title' => "title #{index}" }, 'outline' => [ "h1 page #{index}" ],
                 'alerts' => [], 'captcha' => [], 'password_fields' => 0, 'truncated' => false, 'elements' => elements }
    detect = { 'script_srcs' => scripts, 'iframe_srcs' => iframes, 'dom_markers' => markers }
    { index:, url:, name: '', parent_index: parent, element_id:, value: { 'snapshot' => snapshot, 'detect' => detect } }
  end

  def probe_element(index, role, name, type: 'text', self_visible: true, readonly: false, root: nil,
                    strategies: [ { 'attr' => { 'id' => name.parameterize } } ])
    { 'index' => index, 'tag' => role == 'button' ? 'button' : 'input', 'type' => type, 'role' => role, 'name' => name,
      'visible' => true, 'self_visible' => self_visible, 'readonly' => readonly, 'strategies' => strategies,
      'root_strategies' => root }
  end

  subject(:snapshot) { described_class.call(driver:, markers:).model }

  it 'runs snapshot.js and detect.js in every frame with the markers' do
    snapshot

    expect(driver).to have_received(:evaluate_all_frames)
      .with(include('document.documentElement'), { 'markers' => markers, 'regions' => [] })
  end

  it 'passes the regions to snapshot.js' do
    described_class.call(driver:, markers:, regions: [ '#form' ])

    expect(driver).to have_received(:evaluate_all_frames)
      .with(anything, { 'markers' => markers, 'regions' => [ '#form' ] })
  end

  it 'gives every element a ref, its frame and a role|name|frame fingerprint' do
    expect(snapshot.elements.map { |el| el.values_at('ref', 'frame', 'fingerprint') }).to eq([
      [ 'f0:e0', 'f0', 'button|accept necessary only|f0' ],
      [ 'f1:e0', 'f1', 'textbox|full name|f1' ],
      [ 'f1:e1', 'f1', 'input|resume|f1' ],
      [ 'f2:e0', 'f2', 'combobox|country|f2' ]
    ])
  end

  it 'builds frame paths: an iframe#id hop when the iframe has a CSS-safe id, else the frame url, chained' do
    expect(snapshot.frames.map { |frame| frame.values_at('ref', 'parent', 'frame_path', 'readable') }).to eq([
      [ 'f0', nil, [], true ],
      [ 'f1', 'f0', [ { 'selector' => 'iframe#ashby_embed_iframe' } ], true ],
      [ 'f2', 'f1', [ { 'selector' => 'iframe#ashby_embed_iframe' }, { 'url_contains' => 'https://jobs.ashbyhq.com/widget' } ],
        true ],
      [ 'f3', 'f0', [ { 'url_contains' => 'about:blank' } ], false ], # 'ad:slot' is not a CSS-safe id
      [ 'f4', nil, [ { 'url_contains' => 'https://ads.example/slot' } ], false ] # parent unknown: flat hop, not f0's path
    ])
    expect(snapshot.frames.first).to include('title' => 'title 0', 'outline' => [ 'h1 page 0' ])
  end

  it 'builds Targets that keep the field root only for controls nobody sees themselves' do
    targets = snapshot.elements.to_h { |el| [ el['name'], el['target'] ] }

    expect(targets['Full Name']).to have_attributes(
      frame_path: [ { 'selector' => 'iframe#ashby_embed_iframe' } ],
      strategies: [ { 'attr' => { 'id' => 'full-name' } } ], root: nil, readonly: false
    )
    expect(targets['Resume'].root).to eq([ { 'css' => 'div.dropzone' } ])  # file input: judged on its dropzone
    expect(targets['Country']).to have_attributes(root: [ { 'css' => 'div.select' } ], readonly: true) # transparent
  end

  it 'aggregates evidence over frames and digests the fingerprints' do
    expect(snapshot.evidence).to eq(
      frame_urls: frames.pluck(:url),
      script_srcs: [ 'https://jobs.ashbyhq.com/preply/embed?version=2' ],
      iframe_srcs: [ 'https://jobs.ashbyhq.com/preply/jid?embed=js' ],
      dom_markers: { '.ashby-application-form-field-entry' => 15 }
    )
    expect(snapshot.digest).to eq(Digest::SHA1.hexdigest(snapshot.elements.pluck('fingerprint').join("\n")))
  end
end
