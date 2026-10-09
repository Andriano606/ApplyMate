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

  [ 'Закрита вакансія', 'Вакансія закрита', 'Вакансия закрыта', 'Закрытая вакансия', 'This job is no longer available',
    'This position has been filled', 'We are no longer accepting applications' ].each do |heading|
    it "halts on \"#{heading}\"" do
      expect { check(frames: [ { outline: [ "h1 #{heading}" ] } ]) }
        .to raise_error(Apply::Operation::Engine::Halt) { |halt| expect(halt.code).to eq(:closed_posting) }
    end
  end

  it 'halts despite a language switcher that already holds a value, but not beside an empty field' do
    switcher = snapshot_element(role: 'combobox', name: 'Мова', tag: 'select', filled: true)
    empty = snapshot_element(role: 'textbox', name: 'Email', type: 'email', filled: false)

    expect { check(frames: [ { outline: [ 'h1 Закрита вакансія' ] } ], elements: [ switcher ]) }
      .to raise_error(Apply::Operation::Engine::Halt)
    expect(check(frames: [ { outline: [ 'h1 Закрита вакансія' ] } ], elements: [ switcher, empty ])).to be_nil
  end

  it 'stays silent on filled form controls (after the last fill) beside a closed-wording heading' do
    filled = snapshot_element(role: 'textbox', name: 'Email', type: 'email', filled: true)
    switcher = snapshot_element(role: 'combobox', name: 'Мова', tag: 'select', filled: true)

    expect(check(frames: [ { outline: [ 'h1 Закрита вакансія' ] } ], elements: [ switcher, filled ])).to be_nil
  end

  it 'does not read a jobs filter or a closed-jobs list heading as a closed posting' do
    frames = [ { outline: [ 'h1 Senior Rubyist', 'tabs Відкриті вакансії* | Закриті вакансії', 'h3 Закриті вакансії',
                            'h3 Закрытые вакансии' ] } ]

    expect(check(frames:)).to be_nil
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
