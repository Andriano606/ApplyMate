# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Ai::FillForm do
  include_context 'coidea dou'

  let(:cover_letter) { 'I am an experienced UI/UX designer.' }

  # State after FetchInternalForm: inputs extracted but values not yet AI-filled.
  before do
    apply.update!(inputs: raw_inputs)

    stub_request(:post, /generativelanguage\.googleapis\.com.*generateContent/)
      .to_return(gemini_json_response("```json\n#{{ 'descr' => cover_letter }.to_json}\n```"))
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
      expect(apply.reload.filled_inputs).to include(hash_including('name' => 'descr', 'value' => cover_letter))
    end

    it 'leaves the inputs the AI did not answer (the file, the hidden token) unchanged' do
      run_operation
      filled = apply.reload.filled_inputs.index_by { |input| input['name'] }

      expect(filled['user_cv']).to include('type' => 'file', 'value' => '')
      expect(filled['csrfmiddlewaretoken']).to include('type' => 'hidden', 'value' => '')
    end

    it 'carries over all original input metadata' do
      run_operation
      descr = apply.reload.filled_inputs.find { |input| input['name'] == 'descr' }
      expect(descr).to include('selector' => '#reply_descr', 'tag' => 'textarea', 'type' => 'textarea', 'form_index' => 1)
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
