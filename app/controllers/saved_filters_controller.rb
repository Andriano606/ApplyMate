class SavedFiltersController < ApplicationController
  # create/update rely on the endpoint default (flash + turbo refresh with
  # morph): the search bar keeps its address bar in sync (turbo-form history
  # option), so refreshing the current URL re-renders exactly the on-screen
  # state with the fresh preset data.
  def new
    endpoint SavedFilter::Operation::New, SavedFilter::Component::FormModal
  end

  def create
    endpoint SavedFilter::Operation::Create, SavedFilter::Component::FormModal
  end

  def edit
    endpoint SavedFilter::Operation::Edit, SavedFilter::Component::FormModal
  end

  def update
    endpoint SavedFilter::Operation::Update, SavedFilter::Component::FormModal
  end

  def destroy
    endpoint SavedFilter::Operation::Destroy
  end
end
