# frozen_string_literal: true

class ApplyMate::Component::FlashList < ViewComponent::Base
  def initialize(flash_list:)
    @flash_list = flash_list
  end

  private

  attr_reader :flash_list
end
