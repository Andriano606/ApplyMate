# frozen_string_literal: true

class SourceProfilesController < ApplicationController
  def index
    endpoint SourceProfile::Operation::Index, SourceProfile::Component::Index
  end

  def new
    endpoint SourceProfile::Operation::New, SourceProfile::Component::Modal
  end

  def edit
    endpoint SourceProfile::Operation::Edit, SourceProfile::Component::Modal
  end

  def create
    endpoint SourceProfile::Operation::Create, SourceProfile::Component::Modal
  end

  def update
    endpoint SourceProfile::Operation::Update, SourceProfile::Component::Modal
  end

  def destroy
    endpoint SourceProfile::Operation::Destroy
  end
end
