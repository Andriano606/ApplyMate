# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Gate::ExternalMessenger do
  let(:ctx) { engine_context(create(:apply)) }

  def check(**evidence)
    described_class.new.call(ctx, event: :http_resolved,
                                  evidence: Apply::Operation::Engine::Detect::Evidence.build(**evidence))
  end

  it 'stops on a wa.me number' do
    expect { check(current_urls: [ "https://wa.me/#{unique_phone.delete('+')}" ]) }
      .to raise_error(Apply::Operation::Engine::Halt) { |halt| expect(halt.code).to eq(:external_messenger) }
  end

  %w[https://t.me/hr_bot https://telegram.me/hr https://m.me/company].each do |url|
    it "stops on #{url}" do
      expect { check(current_urls: [ url ]) }.to raise_error(Apply::Operation::Engine::Halt) { |halt|
        expect(halt.code).to eq(:external_messenger)
      }
    end
  end

  it 'ignores a messenger frame embedded in the form page' do
    expect(check(current_urls: [ 'https://jobs.example.com/apply', 'https://t.me/widget' ])).to be_nil
  end

  it 'ignores a messenger hop the chain moved past' do
    expect(check(hops: [ 'https://t.me/x', 'https://jobs.example.com' ], current_urls: [ 'https://jobs.example.com' ]))
      .to be_nil
  end
end
