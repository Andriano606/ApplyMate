# frozen_string_literal: true

class ApplyMate::Ai::Prompt::Base
  def self.call(...)
    new(...).call
  end

  def initialize(*args, **kwargs)
    # Default implementation
  end

  def call
    raise NotImplementedError, "#{self.class} must implement #call"
  end
end
