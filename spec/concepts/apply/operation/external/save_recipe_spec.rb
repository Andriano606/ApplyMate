# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::External::SaveRecipe do
  include_context 'honeytech dou'

  let(:handler) { Apply::Handler::Dou.new(apply:) }
  let(:enriched_inputs) do
    raw_inputs.map { |i| i.merge('fingerprint' => fingerprint_of(i), 'role' => 'custom_question') }
  end

  before do
    apply.update!(
      status:           :completed,
      resolved_url:     HoneytechDou::PEOPLEFORCE_URL,
      fields_source:    'browser',
      trigger_selector: '#apply-btn',
      submit_selector:  'button[type="submit"]',
      submit_text:      'Застосувати',
      inputs:           enriched_inputs
    )
  end

  describe '#call' do
    subject(:run_operation) { described_class.call(apply:, handler:) }

    it 'creates a recipe with navigation, field map and submit meta' do
      expect { run_operation }.to change(FormRecipe, :count).by(1)

      recipe = FormRecipe.last
      expect(recipe.host).to eq('honeytech.peopleforce.io')
      expect(recipe.form_fingerprint).to eq(FormRecipe.form_fingerprint_for(enriched_inputs))
      expect(recipe.navigation).to eq([ { 'op' => 'click', 'selector' => '#apply-btn' } ])
      expect(recipe.field_map).to all(include('fingerprint', 'role'))
      expect(recipe.submit_meta).to include('selector' => 'button[type="submit"]', 'text' => 'Застосувати')
      expect(recipe.success_count).to eq(1)
    end

    it 'keeps the apply completed' do
      run_operation
      expect(apply.reload.status).to eq('completed')
    end

    it 'increments success on repeat and resets failures' do
      run_operation
      FormRecipe.last.update!(fail_count: 2)
      described_class.call(apply:, handler:)

      recipe = FormRecipe.last
      expect(recipe.success_count).to eq(2)
      expect(recipe.fail_count).to eq(0)
      expect(FormRecipe.count).to eq(1)
    end

    it 'does nothing for adapter-sourced applies' do
      apply.update!(fields_source: 'adapter')
      expect { run_operation }.not_to change(FormRecipe, :count)
    end

    it 'does nothing when the apply is not completed' do
      apply.update!(status: :failed_sending_cv)
      expect { run_operation }.not_to change(FormRecipe, :count)
    end
  end
end
