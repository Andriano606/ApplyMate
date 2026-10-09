# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Gate::CloudflareInterstitial do
  let(:ctx) { engine_context(create(:apply)) }

  def check(frames)
    described_class.new.call(ctx, event: :after_goto, snapshot: build_snapshot(frames:),
                                  evidence: Apply::Operation::Engine::Detect::Evidence.empty)
  end

  it 'listens after navigations only' do
    expect(described_class.events).to eq([ :after_goto ])
  end

  it 'halts a main frame titled Just a moment...' do
    expect { check([ { title: 'Just a moment...' } ]) }.to raise_error(Apply::Operation::Engine::Halt) { |halt|
      expect(halt).to have_attributes(code: :bot_wall, detail: 'cloudflare')
    }
  end

  it 'also reads the outline' do
    expect { check([ { title: 'x', outline: [ 'h1 Just a moment' ] } ]) }.to raise_error(Apply::Operation::Engine::Halt)
  end

  it 'ignores a normal page and a challenge title in a sub-frame' do
    expect(check([ { title: 'Senior Rubyist' } ])).to be_nil
    expect(check([ { title: 'Careers' }, { title: 'Just a moment...' } ])).to be_nil
  end
end
