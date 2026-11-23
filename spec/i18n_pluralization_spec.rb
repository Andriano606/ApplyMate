# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Ukrainian pluralization' do
  {
    1 => 'відгук', 3 => 'відгуки', 5 => 'відгуків', 11 => 'відгуків', 21 => 'відгук', 22 => 'відгуки'
  }.each do |count, word|
    it "renders #{count} as #{word}" do
      expect(I18n.t('feedback.index.total', count:, locale: :uk)).to eq("#{count} #{word}")
    end
  end
end
