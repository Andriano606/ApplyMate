class SavedFiltersController < ApplicationController
  def new
    endpoint SavedFilter::Operation::New, SavedFilter::Component::FormModal
  end

  def create
    endpoint SavedFilter::Operation::Create, SavedFilter::Component::FormModal do |m|
      m.success { |result| render_saved_state(result) }
    end
  end

  def edit
    endpoint SavedFilter::Operation::Edit, SavedFilter::Component::FormModal
  end

  def update
    endpoint SavedFilter::Operation::Update, SavedFilter::Component::FormModal do |m|
      m.success { |result| render_saved_state(result) }
    end
  end

  def destroy
    endpoint SavedFilter::Operation::Destroy
  end

  private

  # No page refresh on success: it would reset the search bar state, which lives
  # only in the form. Swap the two nodes that a save changes — the pills row and
  # the save links (now satisfied, so they render away) — and leave the rest.
  def render_saved_state(result)
    state = { include_tags: result.model.include_tags,
              include_ops:  result.model.include_ops,
              exclude_tags: result.model.exclude_tags }
    list    = SavedFilter::Component::List.new(**state)
    actions = SavedFilter::Component::Actions.new(saved_filter: result.model, **state)

    turbo_actions = [ turbo_stream.close_active_modal ]
    turbo_actions << turbo_stream.replace('saved_filters_list', html: render_to_string(list, layout: false))
    turbo_actions << turbo_stream.replace('saved_filter_actions', html: render_to_string(actions, layout: false))
    turbo_actions << turbo_stream.flash([ [ result.message_level, result.notice[:text] ] ]) if result.notice
    render turbo_stream: turbo_actions
  end
end
