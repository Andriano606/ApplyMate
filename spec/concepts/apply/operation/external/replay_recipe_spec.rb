# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::External::ReplayRecipe do
  include_context 'honeytech dou'

  let(:vacancy_external_url) { HoneytechDou::DOU_REDIRECT }
  let(:handler) { Apply::Handler::Dou.new(apply:) }

  let(:recipe_fields) do
    raw_inputs.map do |i|
      i.merge('fingerprint' => fingerprint_of(i))
    end
  end

  let!(:recipe) do
    FormRecipe.create!(
      host:             'honeytech.peopleforce.io',
      form_fingerprint: FormRecipe.form_fingerprint_for(recipe_fields),
      navigation:       [],
      field_map:        recipe_fields.map { |f| { 'fingerprint' => f['fingerprint'], 'role' => 'custom_question' } },
      submit_meta:      { 'selector' => 'button[type="submit"]', 'text' => 'Застосувати' },
      success_count:    1
    )
  end

  before do
    handler.browser = browser
    apply.update!(resolved_url: HoneytechDou::PEOPLEFORCE_URL)
  end

  describe '#call' do
    subject(:run_operation) { described_class.call(apply:, handler:) }

    context 'when the fingerprint matches' do
      it 'stores inputs with roles from the recipe and marks the recipe source' do
        run_operation
        reloaded = apply.reload
        expect(reloaded.fields_source).to eq('recipe')
        expect(reloaded.inputs.map { |i| i['role'] }).to all(eq('custom_question'))
        expect(reloaded.submit_handle).to eq('submit')
      end

      it 'uses no AI at all' do
        run_operation # WebMock would raise on any unstubbed Gemini request
        expect(browser).not_to have_received(:page_digest)
      end
    end

    context 'when the page fingerprint does not match the recipe' do
      before do
        recipe.update!(form_fingerprint: 'different-fingerprint')
      end

      it 'records the failure and leaves the pipeline to the ordinary path' do
        run_operation
        reloaded = apply.reload
        expect(reloaded.fields_source).to be_nil
        expect(reloaded.inputs).to be_blank
        expect(recipe.reload.fail_count).to eq(1)
      end
    end

    context 'when there is no recipe for the host' do
      before { recipe.destroy! }

      it 'is a no-op' do
        run_operation
        expect(apply.reload.fields_source).to be_nil
        expect(browser).not_to have_received(:snapshot_fields)
      end
    end

    context 'when navigation is required and fails' do
      before do
        recipe.update!(navigation: [ { 'op' => 'click', 'selector' => '#apply-btn' } ])
        allow(browser).to receive(:click).with('#apply-btn').and_return(false)
      end

      it 'records the failure without failing the apply' do
        run_operation
        expect(apply.reload.error).to be_nil
        expect(recipe.reload.fail_count).to eq(1)
      end
    end
  end
end
