# frozen_string_literal: true

class PromptsController < ApplicationController
  def index
    endpoint Prompt::Operation::Index, Prompt::Component::Index
  end

  def new
    endpoint Prompt::Operation::New, Prompt::Component::Modal
  end

  def edit
    endpoint Prompt::Operation::Edit, Prompt::Component::Modal
  end

  def create
    endpoint Prompt::Operation::Create, Prompt::Component::Modal
  end

  def update
    endpoint Prompt::Operation::Update, Prompt::Component::Modal
  end

  def destroy
    endpoint Prompt::Operation::Destroy
  end
end
