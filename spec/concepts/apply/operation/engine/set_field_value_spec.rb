# frozen_string_literal: true

require 'rails_helper'

# The write -> settle -> read-back loop with a scripted session; every widget's real write and read-back is
# covered by the :browser specs in spec/concepts/apply/widget/.
RSpec.describe Apply::Operation::Engine::SetFieldValue do
  let(:ctx) { engine_context(create(:apply)) }
  let(:read_values) { {} }
  let(:session) { FakeSession.new(html: '', final_url: 'https://jobs.example.com/apply', read_values:) }
  let(:target) { ApplyMate::Client::Browser::Target.css('#name') }
  let(:field) { answer_field(id: 'name', kind: 'text', widget: 'text', label: 'Full name', target:) }

  before { ctx.open_scope!(:survey, session, 5.minutes.from_now) }

  def set!(value, on: field)
    described_class.call(ctx:, field: on, value:).model
  end

  it 'writes inside the obstruction guard, settles with the widget profile and returns the accepted read-back' do
    expect(set!('Jane Doe')).to eq(Apply::Widget::Base::ReadBack.new(displayed: 'Jane Doe', invalid: false, error_text: nil))
    expect(session.calls.map(&:first)).to eq(%i[snapshot_all fill settle probe])
    expect(session.calls_of(:settle)).to eq([ [ :key ] ])
  end

  it 'settles a file upload with the :file profile' do
    file = answer_field(id: 'cv', kind: 'file', widget: 'file_input', target: ApplyMate::Client::Browser::Target.css('#cv'))

    expect(set!('/tmp/apply-cv/Jane_CV.pdf', on: file).displayed).to eq('Jane_CV.pdf')
    expect(session.calls_of(:settle)).to eq([ [ :file ] ])
  end

  it "runs the widget's fallback write when the first value does not stick" do
    allow(session).to receive(:fill).and_wrap_original do |original, fill_target, text|
      original.call(fill_target, text == 'Jane Doe' ? 'Jane' : text)
    end

    expect(set!('Jane Doe').displayed).to eq('Jane Doe')
    expect(session.calls_of(:type)).to match([ [ target, 'Jane Doe', { delay_ms: Integer } ] ])
    expect(ctx.scratch.trace.last).to include('event' => 'widget_fallback', 'field' => 'name', 'widget' => 'text')
  end

  context 'when the control keeps showing something else' do
    let(:read_values) { { '#name' => 'Jan' } }

    it 'raises Mismatch with the field, the wanted value and the last read-back' do
      expect { set!('Jane Doe') }.to raise_error(Apply::Widget::Mismatch) { |error|
        expect(error).to have_attributes(field:, wanted: 'Jane Doe')
        expect(error.read_back.displayed).to eq('Jan')
      }
      expect(session.calls_of(:fill).size).to eq(2) # write + fallback (clear) only
    end
  end

  context 'when the control shows the value but is invalid' do
    let(:read_values) do
      { '#name' => { 'value' => 'Jane Doe', 'displayed' => 'Jane Doe', 'invalid' => true, 'error_text' => 'Too short' } }
    end

    it 'does not accept it' do
      expect { set!('Jane Doe') }.to raise_error(Apply::Widget::Mismatch, /Too short/)
    end
  end

  it 'raises Mismatch at once when the widget has no fallback' do
    select = answer_field(id: 'country', kind: 'combobox', widget: 'aria_combobox', options: 'dynamic',
                          target: ApplyMate::Client::Browser::Target.css('#country'))

    expect { set!('Atlantis', on: select) }.to raise_error(Apply::Widget::Mismatch)
    expect(session.calls_of(:click)).to all(eq([ select.target ]))
  end

  it 'halts no_widget_driver for a kind no driver handles' do
    range = answer_field(id: 'level', kind: 'range', widget: nil)

    expect { set!('5', on: range) }.to raise_error(Apply::Operation::Engine::Halt) { |halt|
      expect(halt).to have_attributes(code: :no_widget_driver, detail: 'range')
    }
  end
end
