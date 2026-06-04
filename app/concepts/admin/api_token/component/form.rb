# frozen_string_literal: true

class Admin::ApiToken::Component::Form < ApplyMate::Component::Base
  def initialize(form:, **)
    @form = form
  end

  def user_options
    User.order(:email).map { |user| [ user.email, user.id ] }
  end

  private

  attr_reader :form
end
