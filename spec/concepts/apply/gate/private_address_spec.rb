# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Gate::PrivateAddress do
  let(:ctx) { engine_context(create(:apply)) }

  def check(**evidence)
    described_class.new.call(ctx, event: :after_goto,
                                  evidence: Apply::Operation::Engine::Detect::Evidence.build(**evidence))
  end

  %w[
    http://127.0.0.1:3000/admin http://localhost/x http://10.0.0.5/ http://[::1]/ http://192.168.50.155/
    http://localhost.:8080/ http://app.localhost./x
  ].each do |url|
    it "stops on #{url}" do
      expect { check(current_urls: [ 'https://jobs.example.com', url ]) }
        .to raise_error(Apply::Operation::Engine::Halt) { |halt| expect(halt.code).to eq(:private_address) }
    end
  end

  it 'passes public literals and host names without DNS' do
    expect(check(current_urls: [ 'https://jobs.example.com', 'http://8.8.8.8/' ])).to be_nil
  end
end
