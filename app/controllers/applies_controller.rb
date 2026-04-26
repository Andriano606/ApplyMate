# frozen_string_literal: true

class AppliesController < ApplicationController
  def index
    endpoint Apply::Operation::Index, Apply::Component::Index
  end

  def show
    endpoint Apply::Operation::Show, Apply::Component::Show
  end

  def new
    endpoint Apply::Operation::New, Apply::Component::NewModal
  end

  def create
    endpoint Apply::Operation::Create, Apply::Component::NewModal
  end

  def destroy
    endpoint Apply::Operation::Destroy
  end
end
