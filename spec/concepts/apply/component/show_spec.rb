# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Component::Show do
  include_context 'honeytech dou'

  subject(:component) { described_class.new(apply:) }

  describe '#manual_answers' do
    before { apply.update!(filled_inputs: inputs) }

    let(:inputs) do
      [
        { 'name' => 'email', 'accessible_name' => 'Email', 'type' => 'email', 'value' => 'dev@example.com' },
        { 'name' => 'csrf', 'type' => 'hidden', 'value' => 'tok' },
        { 'name' => 'cv', 'accessible_name' => 'Resume', 'type' => 'file', 'value' => '' },
        { 'name' => 'blank', 'accessible_name' => 'Nothing', 'type' => 'text', 'value' => '  ' },
        { 'name' => 'gdpr', 'accessible_name' => 'Acknowledge/Confirm', 'type' => 'checkbox', 'value' => 'on' },
        { 'name' => 'news', 'accessible_name' => 'Newsletter', 'type' => 'checkbox', 'value' => 'false' },
        { 'name' => 'gender', 'accessible_name' => 'Gender identity', 'type' => 'radio', 'value' => 'Man=on',
          'options' => [ { 'label' => 'Woman', 'value' => 'on' }, { 'label' => 'Man', 'value' => 'on' } ] }
      ]
    end

    it 'lists only answers a person has to enter' do
      questions = component.send(:manual_answers).map { |a| a[:question] }
      expect(questions).to contain_exactly('Email', 'Acknowledge/Confirm', 'Newsletter', 'Gender identity')
    end

    it 'reads consents as an instruction rather than "on"' do
      answers = component.send(:manual_answers).index_by { |a| a[:question] }
      expect(answers['Acknowledge/Confirm'][:answer]).to eq(I18n.t('apply.manual.checked'))
      expect(answers['Newsletter'][:answer]).to eq(I18n.t('apply.manual.unchecked'))
    end

    # Radio options routinely share the value "on" — matching by value named the
    # wrong option, turning "Man=on" into "Woman".
    it 'names the chosen option by its label, not by a shared value' do
      answers = component.send(:manual_answers).index_by { |a| a[:question] }
      expect(answers['Gender identity'][:answer]).to eq('Man')
    end
  end
end
