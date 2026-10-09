# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Gate::ClosedPosting do
  let(:ctx) { engine_context(create(:apply)) }
  let(:evidence) { Apply::Operation::Engine::Detect::Evidence.empty }

  def check(frames:, elements: [])
    snapshot = build_snapshot(frames:, elements:)
    described_class.new.call(ctx, event: :after_goto, snapshot:, evidence:)
  end

  it 'listens after navigations and actions' do
    expect(described_class.events).to contain_exactly(:after_goto, :after_action)
  end

  it 'halts a closed-posting page without a fillable control' do
    expect { check(frames: [ { outline: [ 'h1 Senior Rubyist', 'p This position is closed.' ] } ]) }
      .to raise_error(Apply::Operation::Engine::Halt) { |halt|
        expect(halt).to have_attributes(code: :closed_posting, detail: 'position is closed')
      }
  end

  it 'reads the alerts and the Ukrainian wording' do
    expect { check(frames: [ { alerts: [ 'Вакансія закрита' ] } ]) }
      .to raise_error(Apply::Operation::Engine::Halt) { |halt| expect(halt.code).to eq(:closed_posting) }
  end

  it 'stays silent on a form page with the same sentence in the footer' do
    elements = [ snapshot_element(role: 'textbox', name: 'Email', type: 'email') ]

    expect(check(frames: [ { outline: [ 'p Other roles: this position is closed.' ] } ], elements:)).to be_nil
  end

  it 'is not fooled by a control in a different frame' do
    elements = [ snapshot_element(role: 'textbox', name: 'Email', type: 'email', frame: 1) ]

    expect { check(frames: [ { outline: [ 'No longer accepting applications' ] }, {} ], elements:) }
      .to raise_error(Apply::Operation::Engine::Halt)
  end

  it 'stays silent on an ordinary page' do
    expect(check(frames: [ { outline: [ 'h1 Senior Rubyist' ] } ])).to be_nil
  end
end
