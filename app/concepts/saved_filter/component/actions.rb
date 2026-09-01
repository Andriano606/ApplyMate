# frozen_string_literal: true

# The save links of the search bar, plus the hidden field that keeps the active
# preset attached to the search state across turbo-form updates. After a save
# the whole page turbo-refreshes (morph), so the links simply render away once
# the state matches the preset again.
class SavedFilter::Component::Actions < ApplyMate::Component::Base
  def initialize(saved_filter: nil, include_tags: nil, include_ops: nil, exclude_tags: nil, **)
    @saved_filter = saved_filter
    @include_tags = include_tags
    @include_ops  = include_ops
    @exclude_tags = exclude_tags
  end

  private

  def state_present?
    @include_tags.present? || @exclude_tags.present? || @include_ops.present?
  end

  # An untouched preset is already saved, so neither link is offered; editing it
  # brings back both "save as new" and "save into the current one".
  def state_differs_from_saved_filter?
    @saved_filter && !@saved_filter.matches_state?(**current_state_params)
  end

  def show_save_new?
    current_user && state_present? && (@saved_filter.nil? || state_differs_from_saved_filter?)
  end

  def show_save_into?
    current_user && state_differs_from_saved_filter?
  end

  def new_saved_filter_path
    helpers.new_saved_filter_path(**current_state_params)
  end

  # Saves straight away — no modal, the name is already known
  def save_into_saved_filter_path
    helpers.saved_filter_path(@saved_filter, **current_state_params)
  end

  def current_state_params
    { include_tags: @include_tags, include_ops: @include_ops, exclude_tags: @exclude_tags }
  end

  def separator_classes
    'relative flex items-center justify-center w-2 h-full'
  end

  def link_button_label_class
    'text-sm font-medium text-gray-500 dark:text-gray-400 hover:text-gray-700 ' \
      'dark:hover:text-gray-200 transition-colors duration-200 cursor-pointer'
  end
end
