# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::FormFiller do
  let(:browser) { instance_double(ApplyMate::Client::Browser) }
  let(:filler)  { described_class.new(browser:) }

  before do
    allow(browser).to receive(:fill_by_handle)
    allow(browser).to receive(:click_by_handle)
    allow(browser).to receive(:set_checkbox_by_handle)
  end

  describe 'choice questions' do
    let(:radio) do
      { 'name' => 'gender', 'type' => 'radio', 'tag' => 'input', 'handle' => 4,
        'options' => [ { 'label' => 'Woman', 'value' => 'on', 'handle' => 4 },
                       { 'label' => 'Man', 'value' => 'on', 'handle' => 5 } ] }
    end

    it 'clicks the option matching the label' do
      filler.fill([ radio.merge('value' => 'Man') ])
      expect(browser).to have_received(:click_by_handle).with(5)
    end

    # The prompt lists options as "label=value" and the AI sometimes answers with
    # the whole pair — that must not lose the answer.
    it 'accepts a "label=value" answer' do
      filler.fill([ radio.merge('value' => 'Man=on') ])
      expect(browser).to have_received(:click_by_handle).with(5)
    end

    it 'is case and whitespace insensitive' do
      filler.fill([ radio.merge('value' => '  mAn ') ])
      expect(browser).to have_received(:click_by_handle).with(5)
    end

    it 'does nothing when no option matches' do
      filler.fill([ radio.merge('value' => 'Prefer not to say') ])
      expect(browser).not_to have_received(:click_by_handle)
    end
  end

  describe 'autocomplete fields' do
    let(:combo) { { 'name' => 'source', 'type' => 'combobox', 'tag' => 'input', 'handle' => 7 } }

    it 'picks the option from the list instead of typing a value' do
      allow(browser).to receive(:select_from_combobox).with(7, 'Linkedin').and_return('Linkedin')
      filler.fill([ combo.merge('value' => 'Linkedin') ])
      expect(browser).to have_received(:select_from_combobox).with(7, 'Linkedin')
      expect(browser).not_to have_received(:fill_by_handle)
    end

    # Closed lists rarely offer our wording ("DOU" among Preply's sources), and
    # such forms pair the list with a free-text field we already answered.
    it 'falls back to "Other" when the answer is not on the list' do
      allow(browser).to receive(:select_from_combobox).with(7, 'DOU').and_return(nil)
      allow(browser).to receive(:select_from_combobox).with(7, 'Other').and_return('Other')

      filler.fill([ combo.merge('value' => 'DOU') ])
      expect(browser).to have_received(:select_from_combobox).with(7, 'Other')
    end

    it 'leaves nothing behind when even "Other" is missing' do
      allow(browser).to receive(:select_from_combobox).and_return(nil)
      filler.fill([ combo.merge('value' => 'DOU') ])
      expect(browser).to have_received(:fill_by_handle).with(7, '', 'input')
    end
  end

  describe '.remap' do
    let(:stored) do
      [ { 'fingerprint' => 'fp-email', 'name' => 'old_email_name', 'value' => 'dev@example.com', 'role' => 'email' } ]
    end

    it 'matches by fingerprint even when the field was renamed' do
      fresh  = [ { 'fingerprint' => 'fp-email', 'name' => 'new_email_name', 'handle' => 9, 'type' => 'email' } ]
      result = described_class.remap(stored, fresh)
      expect(result.first).to include('handle' => 9, 'value' => 'dev@example.com', 'role' => 'email')
    end

    it 'falls back to the field name when fingerprints changed' do
      fresh  = [ { 'fingerprint' => 'other', 'name' => 'old_email_name', 'handle' => 3 } ]
      expect(described_class.remap(stored, fresh).first).to include('value' => 'dev@example.com')
    end

    it 'drops fresh fields no stored answer belongs to' do
      fresh = [ { 'fingerprint' => 'unknown', 'name' => 'brand_new', 'handle' => 1 } ]
      expect(described_class.remap(stored, fresh)).to be_empty
    end
  end
end
