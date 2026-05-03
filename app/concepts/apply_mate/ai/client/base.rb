# frozen_string_literal: true

class ApplyMate::Ai::Client::Base
  def ask(text)
    raise NotImplementedError
  end

  def self.validate_api_key!(api_key:)
    raise NotImplementedError
  end

  def list_models
    raise NotImplementedError
  end
end
