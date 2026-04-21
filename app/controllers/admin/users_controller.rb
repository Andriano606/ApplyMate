# frozen_string_literal: true

class Admin::UsersController < Admin::BaseController
  def index
    endpoint Admin::User::Operation::Index, Admin::User::Component::Index
  end
end
