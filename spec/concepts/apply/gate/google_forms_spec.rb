# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Gate::GoogleForms do
  let(:ctx) { engine_context(create(:apply)) }

  def check(**evidence)
    described_class.new.call(ctx, event: :http_resolved,
                                  evidence: Apply::Operation::Engine::Detect::Evidence.build(**evidence))
  end

  it 'listens before the browser and after every navigation' do
    expect(described_class.events).to contain_exactly(:http_resolved, :after_goto)
  end

  [
    'https://forms.gle/AbC123',
    'https://docs.google.com/forms/d/e/1FAIpQL/viewform',
    'https://docs.google.com/forms'
  ].each do |url|
    it "sends #{url} to the 'apply yourself' state" do
      expect { check(current_urls: [ url ]) }.to raise_error(Apply::Operation::Engine::Halt) { |halt|
        expect(halt).to have_attributes(code: :manual_apply_required, detail: :google_forms)
      }
    end
  end

  it 'catches a Google Form in an intermediate hop (the sign-in redirect is the final URL)' do
    expect do
      check(hops: [ 'https://forms.gle/x', 'https://accounts.google.com/v3/signin' ],
            current_urls: [ 'https://accounts.google.com/v3/signin' ])
    end.to raise_error(Apply::Operation::Engine::Halt) { |halt| expect(halt.code).to eq(:manual_apply_required) }
  end

  it 'leaves other Google documents and look-alike hosts alone' do
    expect(check(current_urls: [ 'https://docs.google.com/document/d/1/edit', 'https://forms.gle.example.com/x',
                                 'https://example.com/forms' ])).to be_nil
  end
end
