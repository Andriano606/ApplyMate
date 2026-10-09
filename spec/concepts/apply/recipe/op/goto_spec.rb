# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Recipe::Op::Goto do
  let(:apply) { create(:apply, entry_url: 'https://acme.example/jobs/1') }
  let(:ctx) { engine_context(apply) }
  let(:session) { FakeSession.new(html: '', final_url: 'https://acme.example/jobs/1?ref=dou') }

  before { ctx.open_scope!(:survey, session, 5.minutes.from_now) }

  def perform(template)
    described_class.new(url_template: template).perform!(ctx)
  end

  it 'navigates to the entry URL' do
    perform('{entry_url}')

    expect(session.calls_of(:goto)).to eq([ [ 'https://acme.example/jobs/1' ] ])
  end

  it 'navigates to the landing URL (the final URL of the redirect walk)' do
    ctx.apply.landing_url = 'https://acme.example/careers'
    perform('{landing_url}')

    expect(session.calls_of(:goto)).to eq([ [ 'https://acme.example/careers' ] ])
  end

  it 'resolves {current} and literal text around a placeholder' do
    perform('{current}#apply')

    expect(session.calls_of(:goto)).to eq([ [ 'https://acme.example/jobs/1?ref=dou#apply' ] ])
  end

  it 'refuses a placeholder without a value instead of navigating to a broken URL' do
    expect { perform('{canonical_form_url}') }.to raise_error(ArgumentError, /canonical_form_url/)
    expect(session.calls_of(:goto)).to be_empty
  end
end
