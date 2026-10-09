# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Gate::Registry do
  it 'runs every default gate, Google Forms before the sign-in wall' do
    gates = described_class.for(Apply::Platform::Generic)

    expect(gates.map(&:name)).to eq(described_class::DEFAULT)
    expect(gates.index(Apply::Gate::GoogleForms)).to be < gates.index(Apply::Gate::SignInWall)
  end

  it 'orders the gates as the design lists them' do
    expect(described_class::DEFAULT.map { |name| name.demodulize }).to eq(
      %w[PrivateAddress GoogleForms CloudflareInterstitial ExternalMessenger SignInWall DataDome ClosedPosting
         CookieConsent VisibleCaptcha EmailCode]
    )
  end

  it 'adds extra gates and drops skipped ones per platform' do
    platform = Class.new(Apply::Platform::Base) do
      extra_gates 'Apply::Gate::DataDome'
      skipped_gates 'Apply::Gate::CookieConsent', 'Apply::Gate::DataDome'
    end

    expect(described_class.for(platform)).not_to include(Apply::Gate::CookieConsent, Apply::Gate::DataDome)
  end

  it 'lists only gates that declare events the engine fires' do
    described_class::DEFAULT.map(&:constantize).each do |gate|
      expect(gate.events).to be_present.and(all(be_in(Apply::Gate::Base::EVENTS)))
    end
  end
end
