# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::ResolveValues do
  include_context 'honeytech dou'

  def build_input(name:, role:, **attrs)
    base = {
      'name' => name, 'selector' => "[name=\"#{name}\"]", 'form_index' => 0,
      'tag' => 'input', 'type' => 'text', 'label' => '', 'accessible_name' => '',
      'placeholder' => '', 'value' => '', 'role' => role
    }.merge(attrs.stringify_keys)
    base.merge('fingerprint' => fingerprint_of(base))
  end

  before { apply.update!(inputs:) }

  describe '#call' do
    subject(:run_operation) do
      described_class.call(
        apply:,
        prompt_class:  Apply::Ai::Prompt::FillForm,
        schema_class:  Apply::Ai::ResponseSchema::FillForm
      )
    end

    def filled_value(name)
      apply.reload.filled_inputs.find { |i| i['name'] == name }['value']
    end

    context 'with deterministic roles (no AI at all)' do
      let(:inputs) do
        [
          build_input(name: 'apply', role: 'constant_true'),
          build_input(name: 'save_msg_template', role: 'constant_false', type: 'checkbox'),
          build_input(name: 'msg_template_name', role: 'constant_empty', value: 'old'),
          build_input(name: 'csrfmiddlewaretoken', role: 'hidden_passthrough', type: 'hidden', value: 'tok-1'),
          build_input(name: 'cv_file', role: 'cv_file', type: 'file'),
          build_input(name: 'full_name', role: 'full_name'),
          build_input(name: 'email', role: 'email', type: 'email'),
          build_input(name: 'notice_period', role: 'notice_period')
        ]
      end

      before do
        create(:answer_bank, user_profile:, role: 'notice_period', answer: '2 тижні')
      end

      it 'resolves constants to their fixed values' do
        run_operation
        expect(filled_value('apply')).to eq('true')
        expect(filled_value('save_msg_template')).to eq('false')
        expect(filled_value('msg_template_name')).to eq('')
      end

      it 'keeps hidden passthrough and file inputs untouched' do
        run_operation
        expect(filled_value('csrfmiddlewaretoken')).to eq('tok-1')
        expect(filled_value('cv_file')).to eq('')
      end

      it 'takes known roles from the answer bank' do
        run_operation
        expect(filled_value('notice_period')).to eq('2 тижні')
      end

      # The applicant's name comes from the account, never from the profile —
      # UserProfile#name is a label ("Ruby on Rails developer") and once went out
      # to an employer as the candidate's full name.
      it 'fills contact fields from the account, never from AI or the profile label' do
        run_operation
        expect(filled_value('full_name')).to eq(user.name).and eq('Jane Doe')
        expect(filled_value('full_name')).not_to eq(user_profile.name)
        expect(filled_value('email')).to eq('dev@example.com')
      end

      it 'splits the account name for forms that ask for parts' do
        apply.update!(inputs: inputs + [ build_input(name: 'first', role: 'first_name'),
                                         build_input(name: 'last', role: 'last_name') ])
        run_operation
        expect(filled_value('first')).to eq('Jane')
        expect(filled_value('last')).to eq('Doe')
      end

      it 'completes without an error' do
        run_operation
        expect(apply.reload.error).to be_nil
      end
    end

    context 'when the bank answer exists for a custom question' do
      let(:inputs) do
        [ build_input(name: 'react_years', role: 'custom_question',
                      accessible_name: 'How many YEARS of React?') ]
      end

      before do
        create(:answer_bank, :custom, user_profile:,
               question: 'how many years of react?', answer: '5 років')
      end

      it 'answers from the cache without calling the AI' do
        run_operation
        expect(filled_value('react_years')).to eq('5 років')
      end
    end

    context 'when generation is needed (cover letter + unanswered question)' do
      let(:cover_input)  { build_input(name: 'message', role: 'cover_letter', tag: 'textarea', type: 'textarea') }
      let(:custom_input) { build_input(name: 'why_us', role: 'custom_question', accessible_name: 'Why do you want to join us?') }
      let(:inputs)       { [ cover_input, custom_input ] }

      before do
        answers = {
          cover_input['fingerprint']  => 'Мій мотиваційний лист.',
          custom_input['fingerprint'] => 'Бо ваш продукт мені близький.'
        }
        stub_request(:post, /generativelanguage\.googleapis\.com.*generateContent/)
          .to_return(gemini_json_response("```json\n#{answers.to_json}\n```"))
      end

      it 'fills both values from one AI batch' do
        run_operation
        expect(filled_value('message')).to eq('Мій мотиваційний лист.')
        expect(filled_value('why_us')).to eq('Бо ваш продукт мені близький.')
      end

      it 'caches the custom answer into the bank as ai_generated' do
        run_operation
        entry = user_profile.answer_banks.find_by(role: 'custom_question',
                                                  question: 'why do you want to join us?')
        expect(entry).to be_present
        expect(entry.answer).to eq('Бо ваш продукт мені близький.')
        expect(entry.source).to eq('ai_generated')
      end

      it 'does not cache the cover letter — it is vacancy-specific' do
        run_operation
        expect(user_profile.answer_banks.where(role: 'cover_letter')).to be_empty
      end

      it 'answers the same question from the bank on the next apply' do
        run_operation
        second = Apply.create!(user:, vacancy:, source_profile:, user_profile:,
                               ai_integration:, status: :generating_cv)
        second.update!(inputs: [ custom_input ])

        cover_only = {
          cover_input['fingerprint'] => 'Інший лист.'
        }
        stub_request(:post, /generativelanguage\.googleapis\.com.*generateContent/)
          .to_return(gemini_json_response("```json\n#{cover_only.to_json}\n```"))

        described_class.call(apply: second,
                             prompt_class: Apply::Ai::Prompt::FillForm,
                             schema_class: Apply::Ai::ResponseSchema::FillForm)
        answered = second.reload.filled_inputs.find { |i| i['name'] == 'why_us' }
        expect(answered['value']).to eq('Бо ваш продукт мені близький.')
      end
    end
  end
end
