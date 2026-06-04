# frozen_string_literal: true

class Admin::ApiToken::Component::NewModal < ApplyMate::Component::Base
  def initialize(api_token:, **)
    @api_token = api_token
  end

  private

  attr_reader :api_token
end
