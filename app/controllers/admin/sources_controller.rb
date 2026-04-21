# frozen_string_literal: true

class Admin::SourcesController < Admin::BaseController
  def new
    endpoint Admin::Source::Operation::New, Admin::Source::Component::NewModal
  end

  def create
    endpoint Admin::Source::Operation::Create, Admin::Source::Component::NewModal
  end

  def edit
    endpoint Admin::Source::Operation::Edit, Admin::Source::Component::NewModal
  end

  def update
    endpoint Admin::Source::Operation::Update, Admin::Source::Component::NewModal
  end

  def destroy
    endpoint Admin::Source::Operation::Destroy
  end

  def index
    endpoint Admin::Source::Operation::Index, Admin::Source::Component::Index
  end
end
