# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Stage::FetchSchema do
  subject(:run) { described_class.call(ctx:) }

  let(:jid) { '20587adf-cf02-473e-8a80-7b009711a2cf' }
  let(:apply) { create(:apply) }
  let(:ctx) { engine_context(apply) }
  let(:posting) { ApplyMate::Client::Response.new(file_fixture('apply_engine/ashby/api_job_posting.json').read, {}, 200, nil) }
  let(:ashby_match) do
    Apply::Operation::Engine::Detect::Match.new(key: 'ashby', confidence: 0.95, captures: { 'slug' => 'preply', 'jid' => jid },
                                                frame_path: nil, from_alias: false, probable: nil)
  end

  before do
    allow(ApplyMate::Net::Operation::ResolvePublicAddress).to receive(:call) { |url:| FixtureSite.resolution(url) }
    allow(ctx.http).to receive(:post).and_return(posting)
  end

  it 'has a localized stage name' do
    expect(I18n.t("apply.stage.#{described_class.stage}", locale: :uk)).to eq('Отримання полів форми')
    expect(I18n.t("apply.stage.#{described_class.stage}", locale: :en)).to eq('Fetching form fields')
  end

  context 'with Ashby' do
    before { ctx.adopt_match!(ashby_match) }

    it 'persists the schema as applies.fields and the canonical form URL' do
      run

      expect(ctx.schema.size).to eq(15)
      expect(apply.reload.field_list.size).to eq(15)
      expect(apply.field_list).to all(have_attributes(source: 'schema_api'))
      expect(apply.form_url).to eq("https://jobs.ashbyhq.com/preply/#{jid}/application")
      expect(run[:step_result]).to eq('fields' => 15)
    end

    it 'leaves the apply untouched when the schema endpoint fails (the survey reads the DOM)' do
      allow(ctx.http).to receive(:post).and_return(ApplyMate::Client::Response.new('nope', {}, 500, nil))

      expect(run[:step_result]).to eq('fields' => 0)
      expect(ctx.schema).to be_nil
      expect(apply.reload).to have_attributes(fields: be_blank, form_url: nil)
    end

    it 'restores the schema from applies.fields on a later attempt' do
      run
      fresh = engine_context(apply.reload.tap { |row| row.update_columns(state: Apply.states[:queued]) })

      described_class.restore(fresh, run[:step_result])

      expect(fresh.schema.map(&:id)).to eq(ctx.schema.map(&:id))
    end

    it 'digests the match key and captures only' do
      digest = described_class.input_digest(ctx)
      ctx.adopt_match!(ashby_match.with(confidence: 0.99))

      expect(described_class.input_digest(ctx)).to eq(digest)

      ctx.adopt_match!(ashby_match.with(captures: { 'slug' => 'other', 'jid' => jid }))

      expect(described_class.input_digest(ctx)).not_to eq(digest)
    end
  end

  context 'with a generic platform' do
    before { ctx.adopt_match!(Apply::Operation::Engine::Detect::Match.generic) }

    it 'fetches nothing' do
      expect(run[:step_result]).to eq('fields' => 0)
      expect(ctx.http).not_to have_received(:post)
    end

    it 'restores no schema even when a later survey stored schema fields (ReachForm restores what it read)' do
      apply.update!(fields: [ answer_field(id: 'ashby:_systemfield_email', source: 'schema_api').to_h ])

      described_class.restore(ctx, run[:step_result])

      expect(ctx.schema).to be_nil
    end
  end
end
