# frozen_string_literal: true

class AiIntegration < ApplicationRecord
  PROVIDERS = [ :gemini ].freeze

  attr_accessor :fetch_models

  belongs_to :user

  encrypts :api_key

  validates :provider, presence: true, inclusion: { in: PROVIDERS.map(&:to_s) }
  validates :api_key, presence: true
  validates :model, presence: true
  validates :user_id, uniqueness: { scope: :provider, message: I18n.t('ai_integration.errors.already_exists') }
end
