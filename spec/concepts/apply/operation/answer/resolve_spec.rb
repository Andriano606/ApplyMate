# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Answer::Resolve do
  subject(:resolved) { described_class.call(ctx:) }

  let(:user_email) { unique_email('me') }
  let(:ai_phone) { unique_phone }
  let(:user) { create(:user, email: user_email) }
  let(:facts) { { 'ai' => { 'phone' => ai_phone, 'work_authorization' => 'EU citizen' }, 'user' => {} } }
  let(:profile) { create(:user_profile, user:, name: 'Jane Doe', facts:) }
  let(:apply) { create(:apply, user:, user_profile: profile) }
  let(:ctx) { engine_context(apply).tap { |context| context.fields = fields } }
  let(:fields) { [] }
  let(:gemini_url) { /generativelanguage\.googleapis\.com.*generateContent/ }
  let(:decline) { [ { 'label' => 'Male' }, { 'label' => 'Prefer not to say' } ] }

  def stub_ai(*payloads)
    replies = payloads.map { |payload| gemini_json_response("```json\n#{payload.to_json}\n```") }
    stub_request(:post, gemini_url).to_return(*replies)
  end

  def answer_of(id)
    resolved.model[id]
  end

  def halt_code
    resolved
  rescue Apply::Operation::Engine::Halt => e
    e.code
  end

  describe 'sensitive semantics' do
    it 'halts with login_required for a password field' do
      field = answer_field(id: 'pw', kind: 'text', label: 'Password', semantic: 'password')
      ctx.fields = [ field ]

      expect(halt_code).to eq(:login_required)
    end

    context 'with a required demographic field and no fact or decline option' do
      let(:fields) { [ answer_field(id: 'g', kind: 'select', label: 'Gender', required: true, options: [ { 'label' => 'Male' } ]) ] }

      it 'halts with missing_profile_fact naming the field' do
        expect { resolved }.to raise_error(Apply::Operation::Engine::Halt) { |halt|
          expect([ halt.code, halt.detail ]).to eq([ :missing_profile_fact, 'g' ])
        }
      end
    end

    context 'with an optional demographic field' do
      let(:fields) { [ answer_field(id: 'g', kind: 'select', label: 'Gender', options: [ { 'label' => 'Male' } ]) ] }

      it 'leaves it empty and never calls the AI' do
        stub_ai({})

        expect(resolved.model).to eq({})
        expect(a_request(:post, gemini_url)).not_to have_been_made
      end
    end

    context 'with a demographic field that has a decline option' do
      let(:fields) { [ answer_field(id: 'g', kind: 'radio_group', label: 'Gender', required: true, options: decline) ] }

      it 'picks the decline option by policy' do
        expect(answer_of('g')).to include('value' => 'Prefer not to say', 'source' => 'policy')
      end
    end

    context 'with an explicit demographic fact' do
      let(:facts) { { 'user' => { 'demographic' => 'Male' } } }
      let(:fields) { [ answer_field(id: 'g', kind: 'radio_group', label: 'Gender', required: true, options: decline) ] }

      it 'uses the fact, matched to the option' do
        expect(answer_of('g')).to include('value' => 'Male', 'source' => 'fact')
      end
    end

    context 'with a legal_status field' do
      let(:options) { [ { 'label' => 'EU citizen' }, { 'label' => 'I need a visa' } ] }
      let(:fields) { [ answer_field(id: 'wa', kind: 'radio_group', label: 'Work authorization', required: true, options:) ] }

      it 'answers only from the facts' do
        expect(answer_of('wa')).to include('value' => 'EU citizen', 'source' => 'fact')
      end

      it 'halts with missing_profile_fact when the fact is unknown and the field required' do
        profile.update!(facts: nil)

        expect(halt_code).to eq(:missing_profile_fact)
      end

      it 'leaves an optional field empty without calling the AI' do
        profile.update!(facts: nil)
        ctx.fields = [ fields.first.with(required: false) ]
        stub_ai({})

        expect(resolved.model).to eq({})
        expect(a_request(:post, gemini_url)).not_to have_been_made
      end
    end
  end

  describe 'consent' do
    let(:fields) do
      [ answer_field(id: 'c', kind: 'checkbox', label: 'I agree to the privacy policy', required: true),
        answer_field(id: 'n', kind: 'checkbox', label: 'Subscribe to our newsletter') ]
    end

    it 'ticks the consent by policy and never sets the marketing opt-in' do
      expect(resolved.model).to eq('c' => { 'value' => true, 'source' => 'policy', 'confidence' => 1.0 })
    end

    it 'marks the consent policy_pending when the user opted out of automatic consent' do
      user.update!(auto_consent: false)

      expect(answer_of('c')).to include('value' => true, 'source' => 'policy_pending')
    end

    it 'leaves a required consent without an affirmative option to the review form' do
      ctx.fields = [ answer_field(id: 'c', kind: 'radio_group', label: 'GDPR consent', required: true,
                                  options: [ { 'label' => 'Maybe' }, { 'label' => 'Never' } ]) ]

      expect(answer_of('c')).to eq('value' => nil, 'source' => 'policy_pending', 'confidence' => 0.0)
    end
  end

  describe 'facts, cv and overrides' do
    let(:fields) do
      [ answer_field(id: 'e', kind: 'text', label: 'Email', required: true),
        answer_field(id: 'p', kind: 'tel', label: 'Phone'),
        answer_field(id: 'cv', kind: 'file', label: 'Resume'),
        answer_field(id: 'hidden', kind: 'hidden', label: 'csrf') ]
    end

    it 'answers from facts with the account email fallback, and attaches the cv' do
      expect(resolved.model).to eq(
        'e' => { 'value' => user_email, 'source' => 'fact', 'confidence' => 1.0 },
        'p' => { 'value' => ai_phone, 'source' => 'fact', 'confidence' => 1.0 },
        'cv' => { 'value' => { 'file' => 'cv' }, 'source' => 'fact', 'confidence' => 1.0 }
      )
    end

    it 'stores the cv reference as plain JSON' do
      expect(answer_of('cv')['value']).to be_a(Hash)
    end

    it 'lets the platform override a field' do
      platform = instance_double(Apply::Platform::Ashby)
      allow(platform).to receive(:semantic_for)
      allow(platform).to receive(:answer_override) { |field| 'forced' if field.id == 'e' }
      ctx.scratch.platform = platform

      expect(answer_of('e')).to include('value' => 'forced', 'source' => 'override')
    end

    context 'with a file field the platform maps away from cv' do
      let(:fields) { [ answer_field(id: 'letter', kind: 'file', label: 'Cover letter', required:) ] }
      let(:required) { false }

      before do
        platform = instance_double(Apply::Platform::Ashby, answer_override: nil)
        allow(platform).to receive(:semantic_for).and_return('cover_letter')
        ctx.scratch.platform = platform
        stub_ai({ 'letter' => { 'value' => '/etc/passwd', 'confidence' => 1 } })
      end

      it 'leaves an optional one empty and never asks the AI for an upload path' do
        expect(resolved.model).to eq({})
        expect(a_request(:post, gemini_url)).not_to have_been_made
      end

      context 'when it is required' do
        let(:required) { true }

        it 'halts with missing_profile_fact naming the field' do
          expect { resolved }.to raise_error(Apply::Operation::Engine::Halt) { |halt|
            expect([ halt.code, halt.detail ]).to eq([ :missing_profile_fact, 'letter' ])
          }
        end
      end
    end

    it 'returns the fields with their semantics' do
      expect(resolved[:fields].map { |field| [ field.id, field.semantic ] })
        .to eq([ %w[e email], %w[p phone], %w[cv cv], %w[hidden other] ])
    end
  end

  describe 'the AI call' do
    let(:fields) do
      [ answer_field(id: 'e', kind: 'text', label: 'Email', required: true),
        answer_field(id: 'g', kind: 'radio_group', label: 'Gender', options: decline),
        answer_field(id: 'why', kind: 'textarea', label: 'Why us?', required: true, max_length: 10),
        answer_field(id: 'remote', kind: 'radio_group', label: 'Open to remote?', options: AnswerHelpers::YES_NO) ]
    end

    it 'asks once, for the remaining fields only, and validates the answers' do
      stub_ai('why' => { 'value' => 'Because I love Ruby', 'confidence' => 0.9 },
              'remote' => { 'value' => 'yes', 'confidence' => 0.8 })

      expect(resolved.model).to include(
        'why' => { 'value' => 'Because I', 'source' => 'ai', 'confidence' => 0.9 },
        'remote' => { 'value' => 'Yes', 'source' => 'ai', 'confidence' => 0.8 }
      )
      expect(a_request(:post, gemini_url).with { |req| req.body.include?('Why us?') && !req.body.include?('Email') })
        .to have_been_made.once
    end

    it 'retries once with the error list when the answer set is invalid' do
      stub_ai({ 'why' => { 'value' => 'x', 'confidence' => 0.9 }, 'remote' => { 'value' => 'perhaps', 'confidence' => 0.9 } },
              { 'why' => { 'value' => 'x', 'confidence' => 0.9 }, 'remote' => { 'value' => 'No', 'confidence' => 0.9 } })

      expect(answer_of('remote')).to include('value' => 'No')
      expect(a_request(:post, gemini_url)).to have_been_made.twice
      expect(a_request(:post, gemini_url).with { |req| req.body.include?('remote: ') && req.body.include?('rejected') })
        .to have_been_made.once
    end

    it 'halts with invalid_ai_output after a second invalid answer' do
      stub_ai({ 'why' => { 'value' => nil, 'confidence' => 0.9 } })

      expect { resolved }.to raise_error(Apply::Operation::Engine::Halt) { |halt| expect(halt.code).to eq(:invalid_ai_output) }
      expect(a_request(:post, gemini_url)).to have_been_made.twice
    end

    it 'treats an answer that breaks the schema like an invalid one' do
      stub_ai({ 'why' => 'plain text' }, { 'why' => { 'value' => 'ok', 'confidence' => 1 } })

      expect(answer_of('why')).to include('value' => 'ok')
      expect(a_request(:post, gemini_url)).to have_been_made.twice
    end

    it 'keeps the answers of an earlier review (source user) untouched and does not ask for them' do
      apply.update!(answers: { 'why' => answer_entry('My own words', source: 'user', confidence: 1.0) })
      stub_ai('remote' => { 'value' => 'Yes', 'confidence' => 0.9 })

      expect(answer_of('why')).to include('value' => 'My own words', 'source' => 'user')
      expect(a_request(:post, gemini_url).with { |req| !req.body.include?('Why us?') }).to have_been_made.once
    end
  end

  describe 'conditions' do
    let(:fields) do
      [ answer_field(id: 'src', kind: 'select', label: 'How did you hear about us?', options: [ { 'label' => 'Friend' }, { 'label' => 'Other' } ]),
        answer_field(id: 'other', kind: 'text', label: 'Please specify', condition: { 'field' => 'src', 'equals' => 'Other' }) ]
    end

    it 'gives no answer to a field whose condition is unmet' do
      stub_ai('src' => { 'value' => 'Friend', 'confidence' => 0.9 }, 'other' => { 'value' => 'a blog', 'confidence' => 0.9 })

      expect(resolved.model.keys).to eq(%w[src])
    end

    it 'keeps the answer when the condition is met' do
      stub_ai('src' => { 'value' => 'Other', 'confidence' => 0.9 }, 'other' => { 'value' => 'a blog', 'confidence' => 0.9 })

      expect(resolved.model.keys).to match_array(%w[src other])
    end
  end

  it 'answers nothing for an empty form without a call' do
    expect(resolved.model).to eq({})
  end
end
