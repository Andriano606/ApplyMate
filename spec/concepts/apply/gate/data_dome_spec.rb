# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Gate::DataDome do
  let(:ctx) { engine_context(create(:apply)) }

  def check(snapshot: nil, **evidence)
    described_class.new.call(ctx, event: :http_resolved, snapshot:,
                                  evidence: Apply::Operation::Engine::Detect::Evidence.build(**evidence))
  end

  it 'stops on a captcha-delivery.com hop' do
    expect { check(hops: [ 'https://geo.captcha-delivery.com/captcha/?initialCid=x' ]) }
      .to raise_error(Apply::Operation::Engine::Halt) { |halt| expect(halt.code).to eq(:bot_wall) }
  end

  it 'stops on a captcha-delivery.com script' do
    expect { check(current_urls: [ 'https://jobs.example.com' ], script_srcs: [ 'https://js.captcha-delivery.com/x.js' ]) }
      .to raise_error(Apply::Operation::Engine::Halt) { |halt| expect(halt.code).to eq(:bot_wall) }
  end

  it 'stops when the snapshot reports the DataDome frame' do
    snapshot = ApplyMate::Client::Browser::Snapshot.new(frames: [ { 'captcha' => [ 'datadome' ] } ], elements: [],
                                                        evidence: {}, digest: '')

    expect { check(current_urls: [ 'https://jobs.example.com' ], snapshot:) }
      .to raise_error(Apply::Operation::Engine::Halt) { |halt| expect(halt.code).to eq(:bot_wall) }
  end

  it 'passes pages without it' do
    expect(check(current_urls: [ 'https://jobs.example.com' ], script_srcs: [ 'https://cdn.example.com/app.js' ]))
      .to be_nil
  end
end
