# frozen_string_literal: true

require 'hashid/rails'

Hashid::Rails.configure do |config|
  config.salt = Rails.application.secret_key_base.to_s
  config.min_hash_length = 8
  config.override_find = true
  config.override_to_param = true
end
