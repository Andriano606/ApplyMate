# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Stage::AnswerFields do
  let(:user_email) { unique_email('me') }
  let(:user) { create(:user, email: user_email) }
  let(:profile) { create(:user_profile, user:, name: 'Jane Doe', facts: { 'ai' => { 'phone' => unique_phone } }) }
  let(:fields) do
    [ answer_field(id: 'email', kind: 'text', label: 'Email', required: true, semantic: nil),
      answer_field(id: 'why', kind: 'textarea', label: 'Why us?', semantic: nil) ]
  end
  let(:apply) { create(:apply, user:, user_profile: profile, fields: fields.map(&:to_h)) }
  let(:ctx) { engine_context(apply) }
  let(:gemini_url) { /generativelanguage\.googleapis\.com.*generateContent/ }

  before do
    stub_request(:post, gemini_url).to_return(
      gemini_json_response("```json\n#{{ why: { value: 'Because', confidence: 0.9 } }.to_json}\n```")
    )
  end

  it 'has a localized stage name' do
    expect(I18n.t("apply.stage.#{described_class.stage}", locale: :uk)).to eq('Підготовка відповідей')
    expect(I18n.t("apply.stage.#{described_class.stage}", locale: :en)).to eq('Preparing answers')
  end

  it 'persists the answers and the fields with their semantics' do
    run_engine_step(apply, described_class)

    expect(apply.answers).to eq(
      'email' => { 'value' => user_email, 'source' => 'fact', 'confidence' => 1.0 },
      'why' => { 'value' => 'Because', 'source' => 'ai', 'confidence' => 0.9 }
    )
    expect(apply.field_list.map(&:semantic)).to eq(%w[email other])
    expect(apply.apply_steps.find_by(stage: 'answer').result).to eq('answers' => 2)
  end

  context 'when the profile facts were never extracted' do
    let(:ai_phone) { unique_phone }
    let(:profile) { create(:user_profile, user:, name: 'Jane Doe', facts: nil, facts_cv_digest: nil) }
    let(:fields) { [ answer_field(id: 'phone', kind: 'tel', label: 'Phone', required: true, semantic: nil) ] }

    before do
      stub_request(:post, gemini_url).to_return(gemini_json_response(%({"full_name":"Jane Doe","phone":"#{ai_phone}"})))
    end

    it 'extracts them inline with the apply integration before answering' do
      run_engine_step(apply, described_class)

      expect(profile.reload.facts_cv_digest).to eq(Digest::SHA256.hexdigest(profile.cv))
      expect(apply.answers).to eq('phone' => { 'value' => ai_phone, 'source' => 'fact', 'confidence' => 1.0 })
      expect(a_request(:post, gemini_url)).to have_been_made.once
    end

    it 'keeps the same input digest after the extraction, so a resume restores the answers' do
      before_run = described_class.input_digest(ctx)
      described_class.call(ctx:)
      ctx.apply.user_profile.reload

      expect(ctx.apply.user_profile.facts_cv_digest).to be_present
      expect(described_class.input_digest(ctx)).to eq(before_run)
    end
  end

  it 'makes no extraction call while the facts match the CV' do
    run_engine_step(apply, described_class)

    expect(a_request(:post, gemini_url)).to have_been_made.once
  end

  it 'does nothing for an apply without fields' do
    apply.update!(fields: nil)

    expect(described_class.call(ctx:)[:step_result]).to eq('answers' => 0)
    expect(apply.reload.answers).to be_nil
    expect(a_request(:post, gemini_url)).not_to have_been_made
  end

  it 'has nothing to restore: the answers live in applies.answers' do
    expect(described_class.restore(ctx, { 'answers' => 2 })).to be_nil
  end

  describe '.input_digest' do
    def digest
      described_class.input_digest(engine_context_for(apply.reload))
    end

    def engine_context_for(row)
      row.update_columns(state: Apply.states[:queued])
      engine_context(row)
    end

    it 'is stable for the same inputs' do
      expect(digest).to eq(digest)
    end

    it 'does not change when GeneratePdfCv (a later stage) attached the CV: a resume skips the answers' do
      base = digest
      apply.cv.attach(io: StringIO.new('%PDF-1.4 fake'), filename: 'CV.pdf', content_type: 'application/pdf')

      expect(digest).to eq(base)
    end

    it 'does not change when the stored fields carry the semantics this stage persisted' do
      base = digest
      apply.update!(fields: [ fields.first.with(semantic: 'email').to_h, fields.last.with(semantic: 'other').to_h ])

      expect(digest).to eq(base)
    end

    it 'changes when a field classifies differently (autocomplete, lexicon, platform key)' do
      base = digest
      apply.update!(fields: [ fields.first.to_h, fields.last.with(autocomplete: 'family-name').to_h ])

      expect(digest).not_to eq(base)
    end

    # DiscoverFields re-runs on a new fingerprint and persists its fields with semantic nil: this stage must re-run too.
    it 'changes with the platform registry fingerprint' do
      base = digest
      allow(Apply::Platform::Registry).to receive(:fingerprint).and_return('another registry')

      expect(digest).not_to eq(base)
    end

    it 'changes with the fields, the CV, the user facts, the consent setting and the prompt' do
      base = digest

      apply.update!(fields: fields.map { |field| field.with(label: 'Why us?', required: true).to_h })
      expect(digest).not_to eq(base)

      profile.update!(cv: "#{profile.cv} Kyiv")
      first = digest
      expect(first).not_to eq(base)

      profile.update!(facts: profile.facts.merge('user' => { 'phone' => unique_phone }))
      second = digest
      expect(second).not_to eq(first)

      user.update!(auto_consent: false)
      third = digest
      expect(third).not_to eq(second)

      apply.update!(fill_form_prompt: create(:prompt, user:))
      expect(digest).not_to eq(third)
    end
  end
end
