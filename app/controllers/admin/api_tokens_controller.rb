# frozen_string_literal: true

class Admin::ApiTokensController < Admin::BaseController
  def index
    endpoint Admin::ApiToken::Operation::Index, Admin::ApiToken::Component::Index
  end

  def new
    endpoint Admin::ApiToken::Operation::New, Admin::ApiToken::Component::NewModal
  end

  def create
    endpoint Admin::ApiToken::Operation::Create, Admin::ApiToken::Component::NewModal
  end

  def destroy
    endpoint Admin::ApiToken::Operation::Destroy
  end
end
