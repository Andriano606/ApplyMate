# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Bookmarklet do
  include_context 'honeytech dou'

  let(:inputs) do
    [
      { 'name' => '_systemfield_email', 'accessible_name' => 'Email', 'type' => 'email',
        'value' => 'dev@example.com' },
      { 'name' => 'csrf', 'type' => 'hidden', 'value' => 'tok' },
      { 'name' => 'resume', 'accessible_name' => 'Resume', 'type' => 'file', 'value' => '' },
      { 'name' => 'empty', 'accessible_name' => 'Nothing', 'type' => 'text', 'value' => '' },
      { 'name' => 'gdpr', 'accessible_name' => 'Acknowledge/Confirm', 'type' => 'checkbox', 'value' => 'on' },
      { 'name' => 'gender', 'accessible_name' => 'Gender identity', 'type' => 'radio', 'value' => 'Man=on',
        'options' => [ { 'label' => 'Woman', 'value' => 'on' }, { 'label' => 'Man', 'value' => 'on' } ] }
    ]
  end

  before { apply.update!(filled_inputs: inputs) }

  describe '.answers_for' do
    subject(:answers) { described_class.answers_for(apply) }

    it 'carries only what a person still has to enter' do
      expect(answers.map { |a| a[:question] }).to contain_exactly('Email', 'Acknowledge/Confirm', 'Gender identity')
    end

    it 'marks a ticked consent so the script can compare with the live checkbox' do
      expect(answers.find { |a| a[:question] == 'Acknowledge/Confirm' }[:checked]).to be(true)
    end

    # The script clicks by what the option shows, and radio options routinely
    # share the value "on", so the label has to win.
    it 'sends the option label, not the stored "label=value" pair' do
      expect(answers.find { |a| a[:question] == 'Gender identity' }[:value]).to eq('Man')
    end
  end

  describe '.for' do
    subject(:link) { described_class.for(apply) }

    it 'is a self-contained javascript: link with the answers inside' do
      expect(link).to start_with('javascript:')
      expect(CGI.unescape(link)).to include('dev@example.com', 'Acknowledge/Confirm')
    end

    it 'inserts text through execCommand so the page sees a real input event' do
      expect(CGI.unescape(link)).to include("execCommand('insertText'")
    end

    it 'never calls back to us — the form page forbids it (default-src none)' do
      body = CGI.unescape(link)
      expect(body).not_to include('fetch(')
      expect(body).not_to include('createElement(\'script\')')
    end

    it 'is nil when there is nothing to fill' do
      apply.update!(filled_inputs: [])
      expect(link).to be_nil
    end
  end
end
