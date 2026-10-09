# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Recipe::Op::Base do
  let(:target) { ApplyMate::Client::Browser::Target.css('a.apply', has_text: 'Apply', frame_path: [ { 'selector' => 'iframe#embed' } ]) }
  let(:hashes) do
    [
      { 'op' => 'goto', 'url_template' => '{entry_url}' },
      { 'op' => 'unwrap', 'url_template' => '{canonical_form_url}' },
      { 'op' => 'click', 'target' => target.to_h },
      { 'op' => 'press', 'target' => target.to_h, 'key' => 'ArrowDown' },
      { 'op' => 'scroll', 'target' => target.to_h },
      { 'op' => 'switch_tab', 'index' => 1 },
      { 'op' => 'wait_for', 'root' => 'form#apply', 'frame_path' => [ { 'selector' => 'iframe#embed' } ], 'min_fields' => 3 }
    ]
  end

  it 'parses a stored op hash (string or symbol keys) into its class' do
    expect(described_class.parse!('op' => 'goto', 'url_template' => '{entry_url}')).to be_a(Apply::Recipe::Op::Goto)
    expect(described_class.parse!(op: 'unwrap', url_template: '{canonical_form_url}')).to be_a(Apply::Recipe::Op::Unwrap)
    expect(described_class.parse!(op: 'click', target: target.to_h)).to be_a(Apply::Recipe::Op::Click)
  end

  it 'round-trips all seven ops through to_h (the JSON applies.navigation stores)' do
    stored = JSON.parse(hashes.to_json)

    expect(stored.map { |hash| described_class.parse!(hash).to_h }).to eq(hashes)
    expect(hashes.pluck('op')).to match_array(described_class::OPS.keys)
  end

  it 'rejects an unknown op' do
    expect { described_class.parse!('op' => 'fill', 'target' => target.to_h) }.to raise_error(ArgumentError, /unknown recipe op "fill"/)
  end

  it 'rejects an unknown attribute' do
    expect { described_class.parse!('op' => 'click', 'target' => target.to_h, 'value' => 'x') }
      .to raise_error(ArgumentError, /unknown attribute\(s\) value of recipe op click/)
  end

  it 'rejects a missing attribute and an unknown placeholder' do
    expect { described_class.parse!('op' => 'goto') }.to raise_error(KeyError)
    expect { described_class.parse!('op' => 'click') }.to raise_error(KeyError)
    expect { described_class.parse!('op' => 'goto', 'url_template' => '{email}') }.to raise_error(ArgumentError, /email/)
  end

  it 'accepts URL templates only in goto and unwrap (no literal URL)' do
    [ 'https://evil.example/apply', '{current}?next=https://evil.example', 'jobs.example.com/apply' ].each do |template|
      %w[goto unwrap].each do |op|
        expect { described_class.parse!('op' => op, 'url_template' => template) }.to raise_error(ArgumentError, /URL templates only/)
      end
    end
    expect(described_class.parse!('op' => 'goto', 'url_template' => '{current}#apply').url_template).to eq('{current}#apply')
  end

  it 'rejects a malformed target, key, index or wait_for' do
    expect { described_class.parse!('op' => 'click', 'target' => 'a.apply') }.to raise_error(ArgumentError, /Target hash/)
    expect { described_class.parse!('op' => 'press', 'target' => target.to_h, 'key' => 'a') }.to raise_error(ArgumentError, /key "a"/)
    expect { described_class.parse!('op' => 'switch_tab', 'index' => '1') }.to raise_error(ArgumentError, /Integer/)
    expect { described_class.parse!('op' => 'switch_tab', 'index' => -1) }.to raise_error(ArgumentError, /Integer/)
    expect { described_class.parse!('op' => 'wait_for', 'root' => '', 'min_fields' => 1) }.to raise_error(ArgumentError, /CSS/)
    expect { described_class.parse!('op' => 'wait_for', 'root' => 'form', 'min_fields' => 0) }.to raise_error(ArgumentError, /min_fields/)
  end

  it 'maps every op to a class and back' do
    described_class::OPS.each do |op, class_name|
      expect(class_name.constantize.op).to eq(op)
    end
  end

  it 'declares how each op is observed: the gate event, whether it may open a tab, whether it reaches the form' do
    ops = hashes.to_h { |hash| [ hash['op'], described_class.parse!(hash) ] }

    expect(ops.transform_values(&:gate_event)).to eq(
      'goto' => :after_goto, 'unwrap' => :after_goto, 'click' => :after_action, 'press' => :after_action,
      'scroll' => :after_action, 'switch_tab' => :after_goto, 'wait_for' => :after_action
    )
    expect(ops.select { |_, op| op.opens_tab? }.keys).to eq(%w[click press])
    expect(ops.select { |_, op| op.reaches_form? }.keys).to eq(%w[wait_for])
    expect(ops.transform_values(&:settle_kind).compact).to eq('click' => :click, 'press' => :key, 'scroll' => :key)
  end
end
