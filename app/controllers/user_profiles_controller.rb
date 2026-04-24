# frozen_string_literal: true

class UserProfilesController < ApplicationController
  def index
    endpoint UserProfile::Operation::Index, UserProfile::Component::Index
  end

  def new
    endpoint UserProfile::Operation::New, UserProfile::Component::New
  end

  def create
    endpoint UserProfile::Operation::Create, UserProfile::Component::New
  end

  def edit
    endpoint UserProfile::Operation::Edit, UserProfile::Component::Edit
  end

  def update
    endpoint UserProfile::Operation::Update
  end

  def destroy
    endpoint UserProfile::Operation::Destroy
  end
end
