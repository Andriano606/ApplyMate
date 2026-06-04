# frozen_string_literal: true

class ApplyMate::Serializer::Base
  def self.call(model)
    new(model).call
  end

  def initialize(model)
    @model = model
  end

  def call
    raise NoMethodError, "You must define #call in #{self.class}"
  end
end
