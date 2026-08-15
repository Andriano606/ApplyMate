# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Ai::MapFields do
  include_context 'honeytech dou'

  # State after PrepareSession: field IR with fingerprints, roles unmapped.
  let(:enriched_inputs) do
    raw_inputs.map { |i| i.merge('fingerprint' => fingerprint_of(i), 'role' => nil) }
  end

  before { apply.update!(inputs: enriched_inputs) }

  describe '#call' do
    subject(:run_operation) { described_class.call(apply:) }

    context 'with a mix of deterministic and ambiguous fields' do
      before do
        stub_request(:post, /generativelanguage\.googleapis\.com.*generateContent/)
          .to_return(gemini_map_fields)
      end

      it 'maps unambiguous fields deterministically by input type' do
        run_operation
        roles = apply.reload.inputs.index_by { |i| i['name'] }.transform_values { |i| i['role'] }
        expect(roles['career_application_form[email]']).to eq('email')
        expect(roles['career_application_form[resume]']).to eq('cv_file')
      end

      it 'maps ambiguous fields via the AI' do
        run_operation
        roles = apply.reload.inputs.index_by { |i| i['name'] }.transform_values { |i| i['role'] }
        expect(roles['career_application_form[full_name]']).to eq('full_name')
        expect(roles['career_application_form[cover_letter]']).to eq('cover_letter')
      end

      it 'completes without an error' do
        run_operation
        expect(apply.reload.error).to be_nil
      end
    end

    context 'when every field maps deterministically' do
      let(:enriched_inputs) do
        raw_inputs
          .select { |i| %w[email file].include?(i['type']) }
          .map { |i| i.merge('fingerprint' => fingerprint_of(i), 'role' => nil) }
      end

      it 'does not call the AI at all' do
        run_operation # WebMock would raise on any unstubbed Gemini request
        expect(apply.reload.inputs.map { |i| i['role'] }).to contain_exactly('email', 'cv_file')
      end
    end

    context 'when the AI returns a role outside the vocabulary' do
      before do
        mapping = {
          fingerprint_of(raw_inputs[0]) => 'made_up_role',
          fingerprint_of(raw_inputs[2]) => 'cover_letter'
        }
        stub_request(:post, /generativelanguage\.googleapis\.com.*generateContent/)
          .to_return(gemini_json_response("```json\n#{mapping.to_json}\n```"))
      end

      it 'degrades the unknown role to custom_question' do
        run_operation
        full_name = apply.reload.inputs.find { |i| i['name'] == 'career_application_form[full_name]' }
        expect(full_name['role']).to eq('custom_question')
      end
    end

    context 'with a Djinni-style scraper override' do
      let(:source) { create(:source, name: 'Djinni', scraper: 'ApplyMate::Scraper::Djinni') }
      let(:enriched_inputs) do
        [
          { 'name' => 'save_msg_template', 'tag' => 'input', 'type' => 'checkbox',
            'label' => '', 'accessible_name' => '', 'value' => '' },
          { 'name' => 'csrfmiddlewaretoken', 'tag' => 'input', 'type' => 'hidden',
            'label' => '', 'accessible_name' => '', 'value' => 'tok' }
        ].map { |i| i.merge('fingerprint' => fingerprint_of(i), 'role' => nil) }
      end

      it 'applies ROLE_OVERRIDES without any AI call' do
        run_operation
        roles = apply.reload.inputs.map { |i| i['role'] }
        expect(roles).to contain_exactly('constant_false', 'hidden_passthrough')
      end
    end
  end
end
