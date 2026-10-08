# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Recipe::Op::Base do
  it 'parses a stored op hash (string or symbol keys) into its class' do
    expect(described_class.parse!('op' => 'goto', 'url_template' => '{entry_url}')).to be_a(Apply::Recipe::Op::Goto)
    expect(described_class.parse!(op: 'unwrap', url_template: '{canonical_form_url}')).to be_a(Apply::Recipe::Op::Unwrap)
  end

  it 'round-trips through to_h' do
    hash = { 'op' => 'unwrap', 'url_template' => '{canonical_form_url}' }

    expect(described_class.parse!(hash).to_h).to eq(hash)
  end

  it 'rejects an unknown op (the Interpreter ops arrive in 3b)' do
    expect { described_class.parse!('op' => 'click', 'url_template' => '{current}') }.to raise_error(ArgumentError, /unknown recipe op/)
  end

  it 'rejects a missing url_template and an unknown placeholder' do
    expect { described_class.parse!('op' => 'goto') }.to raise_error(KeyError)
    expect { described_class.parse!('op' => 'goto', 'url_template' => '{email}') }.to raise_error(ArgumentError, /email/)
  end

  it 'maps every op to a class and back' do
    described_class::OPS.each do |op, class_name|
      expect(class_name.constantize.op).to eq(op)
    end
  end
end
