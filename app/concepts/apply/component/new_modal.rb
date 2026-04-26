# frozen_string_literal: true

class Apply::Component::NewModal < ApplyMate::Component::Base
  def initialize(apply:, **)
    @apply = apply
  end
end
