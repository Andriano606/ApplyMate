# frozen_string_literal: true

class UserProfile::Component::Form < ApplyMate::Component::Base
  def initialize(form:, **)
    @form = form
  end

  private

  attr_reader :form
end
