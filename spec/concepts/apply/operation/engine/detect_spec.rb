# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Engine::Detect do
  evidence_class = Apply::Operation::Engine::Detect::Evidence
  jid = '20587adf-cf02-473e-8a80-7b009711a2cf'
  dou_hop = 'https://dou.ua/goto/vacancy/?id=375494'
  preply = "https://preply.com/en/careers/apply?ashby_jid=#{jid}&job_title=Lead&utm_source=VX7Kg7NX96"
  frame = "https://jobs.ashbyhq.com/preply/#{jid}?utm_source=VX7Kg7NX96&embed=js"
  embed = 'https://jobs.ashbyhq.com/preply/embed?version=2'

  # Saved evidence of the real Preply chain (research/live_probe.md Part A) and its variations.
  cases = {
    'Preply: http hop chain + rendered iframe' => {
      evidence: { current_urls: [ preply, frame ], hops: [ dou_hop, preply ], iframe_srcs: [ frame ],
                  script_srcs: [ embed ] },
      key: 'ashby', min: 0.95, captures: { 'slug' => 'preply', 'jid' => jid }
    },
    'Preply: rendered iframe only (resume without http evidence)' => {
      evidence: { current_urls: [ 'https://preply.com/en/careers/apply', frame ], iframe_srcs: [ frame ] },
      key: 'ashby', min: 0.95, captures: { 'slug' => 'preply', 'jid' => jid }
    },
    'direct Ashby application URL' => {
      evidence: { current_urls: [ "https://jobs.ashbyhq.com/kissmyapps/#{jid}/application" ] },
      key: 'ashby', min: 0.95, captures: { 'slug' => 'kissmyapps', 'jid' => jid }
    },
    'Ashby DOM markers plus the embed script (slug) and the query param (jid)' => {
      evidence: { current_urls: [ preply ], script_srcs: [ embed ],
                  dom_markers: { '.ashby-application-form-field-entry' => 15 } },
      key: 'ashby', min: 0.95, captures: { 'slug' => 'preply', 'jid' => jid }
    }
  }

  cases.each do |name, row|
    it "detects #{row[:key]} for #{name}" do
      match = described_class.call(evidence: evidence_class.build(**row[:evidence])).model

      expect(match).to be_known
      expect(match.key).to eq(row[:key])
      expect(match.confidence).to be >= row[:min]
      expect(match.captures).to include(row[:captures])
    end
  end

  it 'keeps Preply probable at the http level: only the ashby_jid query param (0.6)' do
    evidence = evidence_class.build(current_urls: [ preply ], hops: [ dou_hop, preply ])

    match = described_class.call(evidence:).model

    expect(match).to be_generic
    expect(match.probable).to have_attributes(key: 'ashby', confidence: 0.6, captures: { 'jid' => jid })
  end

  it 'never scores an intermediate hop (the dou.ua redirector, even a jobs.ashbyhq.com hop)' do
    evidence = evidence_class.build(current_urls: [ 'https://example.com/careers' ],
                                    hops: [ dou_hop, frame, 'https://example.com/careers' ])

    expect(described_class.call(evidence:).model).to have_attributes(key: 'generic', probable: nil)
  end

  it 'cuts a match without its required captures below the threshold' do
    evidence = evidence_class.build(current_urls: [ 'https://careers.example.com/jobs' ],
                                    dom_markers: { '.ashby-application-form-field-entry' => 3 })

    match = described_class.call(evidence:).model

    expect(match).to be_generic
    expect(match.probable.confidence).to eq(Apply::Platform::Registry::THRESHOLD - 0.01)
  end

  it 'counts each signal kind once (max weight) and combines kinds by noisy-or' do
    evidence = evidence_class.build(current_urls: [ 'https://jobs.ashbyhq.com/', 'https://jobs.ashbyhq.com/x' ],
                                    script_srcs: [ embed ])

    probable = described_class.call(evidence:).model.probable

    # host 0.7 (twice, counted once) + script_src 0.85 = 1 - 0.3 * 0.15; no jid -> cut
    expect(probable.confidence).to eq(Apply::Platform::Registry::THRESHOLD - 0.01)
    expect(probable.captures).to eq('slug' => 'preply')
  end

  it 'records the frame path of the frame_src match' do
    evidence = evidence_class.build(current_urls: [ preply ], iframe_srcs: [ frame ])

    expect(described_class.call(evidence:).model.frame_path)
      .to eq([ { 'url_contains' => "jobs.ashbyhq.com/preply/#{jid}" } ])
  end

  it 'scores a host alias at HOST_ALIAS_WEIGHT, which needs a second signal to pass' do
    alias_entry = { 'host' => 'preply.com', 'platform' => 'ashby', 'captures' => { 'slug' => 'preply' } }
    alone = evidence_class.build(current_urls: [ 'https://preply.com/en/careers' ], host_aliases: [ alias_entry ])
    with_query = evidence_class.build(current_urls: [ preply ], host_aliases: [ alias_entry ])

    expect(described_class.call(evidence: alone).model).to be_generic
    expect(described_class.call(evidence: with_query).model)
      .to have_attributes(key: 'ashby', confidence: 0.8, from_alias: true, captures: { 'slug' => 'preply', 'jid' => jid })
  end

  it 'returns generic without a probable platform for unrelated evidence' do
    expect(described_class.call(evidence: evidence_class.empty).model).to have_attributes(key: 'generic', probable: nil)
  end

  describe 'Evidence' do
    it 'merges lists (union) and keeps the larger DOM marker count' do
      first = evidence_class.build(current_urls: [ 'https://a.test/' ], dom_markers: { '.x' => 2 })
      second = evidence_class.build(current_urls: [ 'https://a.test/', 'https://b.test/' ], dom_markers: { '.x' => 1 })

      merged = first.merge(second)

      expect(merged.current_urls).to eq([ 'https://a.test/', 'https://b.test/' ])
      expect(merged.dom_markers).to eq('.x' => 2)
    end

    it 'caps every list' do
      urls = Array.new(described_class::MAX_ENTRIES + 5) { |i| "https://cdn.test/#{i}.js" }

      expect(evidence_class.build(script_srcs: urls).script_srcs.size).to eq(described_class::MAX_ENTRIES)
    end

    it 'round-trips through a hash (step results)' do
      evidence = evidence_class.build(current_urls: [ preply ], hops: [ dou_hop ], dom_markers: { '.x' => 1 })

      expect(evidence_class.from_h(JSON.parse(evidence.to_h.to_json))).to eq(evidence)
    end
  end

  describe 'Match' do
    it 'round-trips through a hash with its probable match' do
      match = described_class.call(evidence: evidence_class.build(current_urls: [ preply ])).model

      expect(Apply::Operation::Engine::Detect::Match.from_h(JSON.parse(match.to_h.to_json))).to eq(match)
    end
  end
end
