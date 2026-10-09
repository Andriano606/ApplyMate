# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Stage::DiscoverFields do
  let(:apply) { create(:apply) }
  let(:ctx) { engine_context(apply) }
  let(:jid) { '20587adf-cf02-473e-8a80-7b009711a2cf' }
  let(:form_root) { ApplyMate::Client::Browser::Target.css('#form[role="tabpanel"]') }
  # The production Snapshot of the fixture's Ashby application page (see build_field_inventory_spec.rb).
  let(:snapshot) do
    raw = JSON.parse(file_fixture('apply_engine/ashby/application_frames.json').read).map { |frame| frame.transform_keys(&:to_sym) }
    driver = instance_double(ApplyMate::Client::Browser::Driver::Playwright, evaluate_all_frames: raw)
    ApplyMate::Client::Browser::Operation::SnapshotAll.call(driver:, regions: Apply::Operation::Engine::FormElements.regions(ctx)).model
  end
  let(:session) { FakeSession.new(html: '', final_url: "https://jobs.ashbyhq.com/preply/#{jid}/application", snapshot:) }

  before do
    ctx.adopt_match!(Apply::Operation::Engine::Detect::Match.new(
      key: 'ashby', confidence: 0.95, captures: { 'slug' => 'preply', 'jid' => jid }, frame_path: nil, from_alias: false,
      probable: nil
    ))
    allow(ApplyMate::Net::Operation::ResolvePublicAddress).to receive(:call) { |url:| FixtureSite.resolution(url) }
    allow(ctx.http).to receive(:post)
      .and_return(ApplyMate::Client::Response.new(file_fixture('apply_engine/ashby/api_job_posting.json').read, {}, 200, nil))
    ctx.schema = ctx.platform.fetch_schema
    ctx.form_root = form_root
    ctx.open_scope!(:survey, session, 5.minutes.from_now)
  end

  it 'has a localized stage name' do
    expect(I18n.t("apply.stage.#{described_class.stage}", locale: :uk)).to be_present
    expect(I18n.t("apply.stage.#{described_class.stage}", locale: :en)).to be_present
  end

  it 'snapshots the form root and the excluded regions, runs the after_goto gates and persists the inventory' do
    allow(Apply::Operation::Engine::RunGates).to receive(:call).and_call_original

    expect(described_class.call(ctx:)[:step_result]).to eq('fields' => 15)
    expect(session.calls_of(:snapshot_all).first).to eq([ { markers: Apply::Platform::Registry.dom_markers,
                                                            regions: [ '#form[role="tabpanel"]', '.ashby-application-form-autofill-input-root' ] } ])
    expect(Apply::Operation::Engine::RunGates).to have_received(:call).with(ctx:, event: :after_goto, snapshot:)
    expect(ctx.fields.map(&:id)).to eq(ctx.schema.map(&:id))
    expect(apply.reload.field_list).to eq(ctx.fields)
    expect(ctx.scratch.trace.last).to include('event' => 'fields_discovered', 'total' => 15, 'without_widget' => [])
  end

  it 'restores the inventory from applies.fields' do
    described_class.call(ctx:)
    fields = ctx.fields
    ctx.fields = nil

    described_class.restore(ctx, { 'fields' => 15 })

    expect(ctx.fields).to eq(fields)
  end

  context 'when reconciling with the stored inventory' do
    let(:stored_extra) do
      answer_field(id: 'ashby:gone', label: 'Gone question', required: false,
                   signature: Apply::Field.signature_for(label: 'Gone question', kind: 'text', option_labels: nil))
    end

    it 'keeps the stored ids, drops an optional field that disappeared and never reuses stored targets' do
      described_class.call(ctx:)
      stale = ctx.fields.map { |field| field.with(target: ApplyMate::Client::Browser::Target.css('#stale')) }
      apply.update_columns(fields: [ *stale, stored_extra ].map(&:to_h))

      described_class.call(ctx:, reconcile: true)

      expect(ctx.fields.map(&:id)).to eq(stale.map(&:id))
      expect(ctx.fields.map(&:target)).not_to include(ApplyMate::Client::Browser::Target.css('#stale'))
      expect(apply.reload.field_list.map(&:id)).not_to include('ashby:gone')
    end

    it 'halts target_not_found when a required stored field is gone' do
      apply.update_columns(fields: [ stored_extra.with(required: true).to_h ])

      expect { described_class.call(ctx:, reconcile: true) }.to raise_error(Apply::Operation::Engine::Halt) { |halt|
        expect(halt).to have_attributes(code: :target_not_found, detail: 'ashby:gone')
      }
    end
  end

  context 'with a Generic form (the Navigator reached it: R2 once more)' do
    let(:generic_page) do
      build_snapshot(frames: [ { url: 'https://acme.example/jobs/1' } ], elements: names.map { |name, type|
        snapshot_element(name:, type:, regions: [ 'form' ])
      })
    end
    let(:session) { FakeSession.new(html: '', final_url: 'https://acme.example/jobs/1', snapshot: generic_page) }

    before do
      ctx.adopt_match!(Apply::Operation::Engine::Detect::Match.generic)
      ctx.schema = nil
      ctx.form_root = ApplyMate::Client::Browser::Target.css('form')
    end

    context 'when it asks who the candidate is' do
      let(:names) { [ [ 'Full name', 'text' ], [ 'Email', 'email' ], [ 'Phone', 'tel' ] ] }

      it 'builds the inventory from the DOM' do
        expect(described_class.call(ctx:)[:step_result]).to eq('fields' => 3)
        expect(ctx.fields.map(&:label)).to eq([ 'Full name', 'Email', 'Phone' ])
      end
    end

    context 'when the root now holds an e-mail-only box' do
      let(:names) { [ [ 'Email', 'email' ] ] }

      it 'halts not_a_form and persists no fields' do
        expect { described_class.call(ctx:) }.to raise_error(Apply::Operation::Engine::Halt) { |halt|
          expect(halt).to have_attributes(code: :not_a_form, detail: 'not an application form (too_few_fields)')
        }
        expect(apply.reload.fields).to be_nil
      end
    end
  end

  describe '.input_digest' do
    it 'is stable for the same match and schema' do
      expect(described_class.input_digest(ctx)).to eq(described_class.input_digest(ctx))
    end

    it 'changes with the schema and the platform registry' do
      base = described_class.input_digest(ctx)

      allow(Apply::Platform::Registry).to receive(:fingerprint).and_return('other')
      expect(described_class.input_digest(ctx)).not_to eq(base)
    end

    it 'is nil when reconciling (always re-runs)' do
      expect(described_class.input_digest(ctx, reconcile: true)).to be_nil
    end
  end
end
