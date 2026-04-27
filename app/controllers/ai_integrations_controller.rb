# frozen_string_literal: true

class AiIntegrationsController < ApplicationController
  def index
    endpoint AiIntegration::Operation::Index, AiIntegration::Component::Index
  end

  def new
    endpoint AiIntegration::Operation::New, AiIntegration::Component::Modal
  end

  def edit
    endpoint AiIntegration::Operation::Edit, AiIntegration::Component::Modal
  end

  def update
    endpoint AiIntegration::Operation::Update, AiIntegration::Component::Modal
  end

  def create
    endpoint AiIntegration::Operation::Create, AiIntegration::Component::Modal
  end

  def destroy
    endpoint AiIntegration::Operation::Destroy
  end
end
