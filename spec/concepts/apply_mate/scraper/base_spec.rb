# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ApplyMate::Scraper::Base do
  describe '.session_cookie_name' do
    it 'must be declared by each platform' do
      expect { described_class.session_cookie_name }.to raise_error(NotImplementedError)
    end
  end
end
