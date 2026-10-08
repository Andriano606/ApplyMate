# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Ai::FillForm do
  include_context 'honeytech dou'

  # State after FetchExternalForm: inputs extracted but values not yet AI-filled.
  before do
    apply.update!(inputs: raw_inputs)

    stub_request(:post, /generativelanguage\.googleapis\.com.*generateContent/)
      .to_return(gemini_fill_form)
  end

  describe '#call' do
    subject(:run_operation) do
      described_class.call(
        ctx:           engine_context(apply),
        prompt_class:  Apply::Ai::Prompt::FillForm,
        schema_class:  Apply::Ai::ResponseSchema::FillForm
      )
    end

    it 'merges AI values into filled_inputs' do
      run_operation
      filled = apply.reload.filled_inputs
      expect(filled).to include(
        hash_including('name' => 'career_application_form[full_name]', 'value' => 'Jane Doe'),
        hash_including('name' => 'career_application_form[email]',     'value' => user_email)
      )
    end

    it 'preserves the file input without modification' do
      run_operation
      resume = apply.reload.filled_inputs.find { |i| i['name'] == 'career_application_form[resume]' }
      expect(resume).to include('type' => 'file', 'value' => '')
    end

    it 'carries over all original input metadata' do
      run_operation
      full_name = apply.reload.filled_inputs.find { |i| i['name'] == 'career_application_form[full_name]' }
      expect(full_name).to include('selector' => '[name="career_application_form[full_name]"]',
                                   'tag' => 'input', 'type' => 'text', 'form_index' => 0)
    end

    it 'succeeds as the fill_form stage' do
      expect(run_operation).to be_success
      expect(described_class.stage).to eq(:fill_form)
    end

    context 'when the AI returns an empty object' do
      before do
        stub_request(:post, /generativelanguage\.googleapis\.com.*generateContent/).to_return(gemini_json_response('{}'))
      end

      it 'halts with invalid_ai_output' do
        expect { run_operation }.to raise_error(Apply::Operation::Engine::Halt) { |halt|
          expect(halt.code).to eq(:invalid_ai_output)
        }
        expect(apply.reload.filled_inputs).to be_nil
      end
    end
  end
end
