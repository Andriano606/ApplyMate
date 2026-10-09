# frozen_string_literal: true

require 'rails_helper'

# FakeSession (spec/support/fake_session.rb) stands in for Session in every step spec; this keeps it from drifting.
RSpec.describe FakeSession do
  let(:session_methods) { ApplyMate::Client::Browser::Session.public_instance_methods(false) }

  it 'implements every public Session method' do
    expect(described_class.public_instance_methods(false)).to include(*session_methods)
  end

  it 'takes the same parameters as Session for each of them' do
    session_methods.each do |name|
      expect(described_class.instance_method(name).parameters)
        .to eq(ApplyMate::Client::Browser::Session.instance_method(name).parameters), "parameters of ##{name} differ"
    end
  end
end
