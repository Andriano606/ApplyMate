# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FormRecipe do
  describe '.form_fingerprint_for' do
    let(:fields) do
      [ { 'fingerprint' => 'bbb' }, { 'fingerprint' => 'aaa' }, { 'fingerprint' => 'ccc' } ]
    end

    it 'is order-independent (sorted before hashing)' do
      expect(described_class.form_fingerprint_for(fields))
        .to eq(described_class.form_fingerprint_for(fields.reverse))
    end

    it 'changes when a field is added' do
      expect(described_class.form_fingerprint_for(fields))
        .not_to eq(described_class.form_fingerprint_for(fields + [ { 'fingerprint' => 'ddd' } ]))
    end
  end

  describe '.normalize_host' do
    it 'downcases and strips www' do
      expect(described_class.normalize_host('https://WWW.Acme.COM/careers')).to eq('acme.com')
    end

    it 'returns nil for garbage' do
      expect(described_class.normalize_host('not a url::')).to be_nil
    end
  end

  describe '#record_failure!' do
    let(:recipe) { described_class.create!(host: 'acme.com', form_fingerprint: 'fp') }

    it 'increments the counter and destroys the recipe on the third failure' do
      2.times { recipe.record_failure! }
      expect(recipe.reload.fail_count).to eq(2)

      recipe.record_failure!
      expect(described_class.exists?(recipe.id)).to be(false)
    end
  end

  describe '#record_success!' do
    let(:recipe) { described_class.create!(host: 'acme.com', form_fingerprint: 'fp', fail_count: 2) }

    it 'increments successes and resets failures' do
      recipe.record_success!
      reloaded = recipe.reload
      expect(reloaded.success_count).to eq(1)
      expect(reloaded.fail_count).to eq(0)
      expect(reloaded.last_success_at).to be_present
    end
  end
end
