# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Source, type: :model do
  describe '#session_cookie_name' do
    it "delegates to the configured scraper's declaration" do
      source = build(:source, scraper: 'ApplyMate::Scraper::Dou')
      allow(ApplyMate::Scraper::Dou).to receive(:session_cookie_name).and_return('dou_session')

      expect(source.session_cookie_name).to eq('dou_session')
    end
  end
end
