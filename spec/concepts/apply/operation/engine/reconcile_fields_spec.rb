# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Engine::ReconcileFields do
  def target(css)
    ApplyMate::Client::Browser::Target.css(css)
  end

  def reconcile(stored:, fresh:)
    described_class.call(stored:, fresh:).model
  end

  it 'matches by id and takes the fresh target, widget and DOM state under the stored id, semantic and condition' do
    default_email = unique_email('jane')
    stored = answer_field(id: 'ashby:email', semantic: 'email', condition: { 'field' => 'x', 'equals' => 'y' },
                          target: target('#old'), widget: 'text')
    fresh = answer_field(id: 'ashby:email', semantic: nil, condition: nil, target: target('#new'), widget: 'text',
                         default_value: default_email)

    expect(reconcile(stored: [ stored ], fresh: [ fresh ]).sole).to have_attributes(
      id: 'ashby:email', semantic: 'email', condition: { 'field' => 'x', 'equals' => 'y' }, target: target('#new'),
      default_value: default_email
    )
  end

  it 'matches by signature and ordinal when the id changed (generic ids are not stable across renders)' do
    stored = [ answer_field(id: 'f_sig_0', signature: 'sig', ordinal: 0, target: target('#a')),
               answer_field(id: 'f_sig_1', signature: 'sig', ordinal: 1, target: target('#b')) ]
    fresh = [ answer_field(id: 'new_1', signature: 'sig', ordinal: 1, target: target('#y')),
              answer_field(id: 'new_0', signature: 'sig', ordinal: 0, target: target('#x')) ]

    expect(reconcile(stored:, fresh:).map { |field| [ field.id, field.target ] })
      .to eq([ [ 'f_sig_0', target('#x') ], [ 'f_sig_1', target('#y') ] ])
  end

  it 'never takes a stored target, even when no fresh field shares the id' do
    stored = answer_field(id: 'f_a_0', signature: 'a', ordinal: 0, target: target('#stored'))
    fresh = answer_field(id: 'f_a_0', signature: 'a', ordinal: 0, target: target('#fresh'))

    expect(reconcile(stored: [ stored ], fresh: [ fresh ]).map(&:target)).to eq([ target('#fresh') ])
  end

  it 'uses each fresh field once' do
    stored = [ answer_field(id: 'ashby:a', signature: 's', ordinal: 0), answer_field(id: 'f_s_0', signature: 's', ordinal: 0) ]
    fresh = [ answer_field(id: 'ashby:a', signature: 's', ordinal: 0) ]

    expect(reconcile(stored:, fresh:).map(&:id)).to eq([ 'ashby:a' ])
  end

  it 'drops a stored optional field that is not on the page and appends fresh fields nobody matched' do
    stored = [ answer_field(id: 'gone', signature: 'g'), answer_field(id: 'kept', signature: 'k') ]
    fresh = [ answer_field(id: 'new', signature: 'n'), answer_field(id: 'kept', signature: 'k') ]

    expect(reconcile(stored:, fresh:).map(&:id)).to eq(%w[kept new])
  end

  it 'halts target_not_found when a stored required field is missing' do
    stored = [ answer_field(id: 'ashby:resume', signature: 'r', required: true) ]

    expect { reconcile(stored:, fresh: [ answer_field(id: 'other', signature: 'o') ]) }
      .to raise_error(Apply::Operation::Engine::Halt) { |halt| expect(halt).to have_attributes(code: :target_not_found, detail: 'ashby:resume') }
  end

  it 'keeps the wizard page of a stored follow-up field it matches' do
    stored = answer_field(id: 'f_cover_0', signature: 'cover', page: 2, target: target('#old'))
    fresh = answer_field(id: 'f_cover_0', signature: 'cover', target: target('#cover'))

    expect(reconcile(stored: [ stored ], fresh: [ fresh ]).sole).to have_attributes(page: 2, target: target('#cover'))
  end

  it 'keeps a stored field of a later wizard page without a target, even a required one (its page is behind Next)' do
    stored = [ answer_field(id: 'name', signature: 'n', required: true, target: target('#name')),
               answer_field(id: 'cover', signature: 'c', required: true, page: 2, target: target('#stale')) ]
    outcome = described_class.call(stored:, fresh: [ answer_field(id: 'name', signature: 'n', target: target('#name-now')) ])

    expect(outcome.model.map { |field| [ field.id, field.target ] }).to eq([ [ 'name', target('#name-now') ], [ 'cover', nil ] ])
    expect(outcome[:present]).to eq(%w[name])
  end

  describe 'strict: false (a later wizard page, Engine::AnswerFollowups)' do
    let(:stored) do
      [ answer_field(id: 'name', signature: 'n', required: true, target: target('#name')),
        answer_field(id: 'phone', signature: 'p', target: target('#phone')),
        answer_field(id: 'cover', signature: 'c', page: 2, target: target('#cover')) ]
    end
    let(:fresh) do
      [ answer_field(id: 'cover', signature: 'c', target: target('#cover-now')),
        answer_field(id: 'consent', signature: 'k', required: true, target: target('#consent')) ]
    end
    let(:outcome) { described_class.call(stored:, fresh:, strict: false) }

    it 'keeps every stored field of an earlier page without a target instead of halting, and appends the new ones' do
      expect(outcome.model.map { |field| [ field.id, field.target ] }).to eq(
        [ [ 'name', nil ], [ 'phone', nil ], [ 'cover', target('#cover-now') ], [ 'consent', target('#consent') ] ]
      )
    end

    it 'reports the fields on the page now' do
      expect(outcome[:present]).to eq(%w[cover consent])
    end
  end

  it 'halts unexpected_error when the result repeats an id (a corrupt stored list)' do
    stored = [ answer_field(id: 'dup', signature: 'a', ordinal: 0), answer_field(id: 'dup', signature: 'b', ordinal: 0) ]
    fresh = [ answer_field(id: 'x', signature: 'a', ordinal: 0), answer_field(id: 'y', signature: 'b', ordinal: 0) ]

    expect { reconcile(stored:, fresh:) }
      .to raise_error(Apply::Operation::Engine::Halt) { |halt| expect(halt).to have_attributes(code: :unexpected_error, detail: 'field id collision') }
  end
end
