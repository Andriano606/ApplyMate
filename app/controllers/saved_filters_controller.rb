class SavedFiltersController < ApplicationController
  def new
    endpoint SavedFilter::Operation::New, SavedFilter::Component::NewModal
  end

  # No page refresh on success: it would reset the search bar state,
  # which lives only in the form. Swap the pills row in place instead.
  def create
    endpoint SavedFilter::Operation::Create, SavedFilter::Component::NewModal do |m|
      m.success do |result|
        list = SavedFilter::Component::List.new(include_tags: result.model.include_tags,
                                                include_ops:  result.model.include_ops,
                                                exclude_tags: result.model.exclude_tags)
        turbo_actions = [ turbo_stream.close_active_modal ]
        turbo_actions << turbo_stream.replace('saved_filters_list', html: render_to_string(list, layout: false))
        turbo_actions << turbo_stream.flash([ [ result.message_level, result.notice[:text] ] ]) if result.notice
        render turbo_stream: turbo_actions
      end
    end
  end

  def destroy
    endpoint SavedFilter::Operation::Destroy
  end
end
