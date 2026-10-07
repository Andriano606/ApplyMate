# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ApplyMate::Client::Browser::Target do
  let(:hash) do
    {
      'type' => 'browser',
      'frame_path' => [ { 'selector' => 'iframe#embed' }, { 'url_contains' => 'ashbyhq.com' } ],
      'strategies' => [ { 'attr' => { 'name' => 'email' } }, { 'role' => 'textbox', 'name' => 'Email' },
                        { 'label' => 'Email' }, { 'css' => 'input', 'has_text' => 'x', 'nth' => 1 } ],
      'root' => [ { 'css' => '#email-root' } ],
      'readonly' => true
    }
  end

  it 'round-trips through to_h / from_h' do
    target = described_class.from_h(hash)

    expect(target.to_h).to eq(hash)
    expect(described_class.from_h(target.to_h)).to eq(target)
    expect(target).to be_readonly
  end

  it 'accepts symbol keys (jsonb in memory) and defaults frame_path, root and readonly' do
    target = described_class.from_h(strategies: [ { css: '#a' } ])

    expect(target).to have_attributes(frame_path: [], strategies: [ { 'css' => '#a' } ], root: nil, readonly: false)
    expect(target).not_to be_readonly
  end

  it 'requires strategies' do
    expect { described_class.from_h('frame_path' => []) }.to raise_error(KeyError)
  end

  describe '.css' do
    it 'builds a single css strategy and drops unset options' do
      expect(described_class.css('button.apply').strategies).to eq([ { 'css' => 'button.apply' } ])
      expect(described_class.css('button', has_text: 'Apply', nth: 0, frame_path: [ { 'name' => 'f' } ]))
        .to have_attributes(strategies: [ { 'css' => 'button', 'has_text' => 'Apply', 'nth' => 0 } ],
                            frame_path: [ { 'name' => 'f' } ], root: nil, readonly: false)
    end
  end
end
