# frozen_string_literal: true

class Admin::Source::Component::NewModal < ApplyMate::Component::Base
  def initialize(source:, **)
    @source = source
  end

  private

  attr_reader :source
end
