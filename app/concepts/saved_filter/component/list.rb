# frozen_string_literal: true

# Saved-filter pills under the search bar. Wrapped in a stable #saved_filters_list
# node so SavedFiltersController#create can replace it via turbo stream without
# refreshing the page (a refresh would reset the not-yet-saved search bar state).
class SavedFilter::Component::List < ApplyMate::Component::Base
  def initialize(include_tags: nil, include_ops: nil, exclude_tags: nil, **)
    @include_tags = include_tags
    @include_ops  = include_ops
    @exclude_tags = exclude_tags
  end

  private

  def saved_filters
    @saved_filters ||= current_user ? current_user.saved_filters.order(:name) : []
  end

  def saved_filter_active?(saved_filter)
    saved_filter.include_tags == normalize_prop(@include_tags) &&
      saved_filter.include_ops == normalize_prop(@include_ops) &&
      saved_filter.exclude_tags == normalize_prop(@exclude_tags)
  end

  def normalize_prop(prop)
    prop || []
  end

  def saved_filter_pill_classes(saved_filter)
    base = 'inline-flex items-center gap-1.5 pl-3 pr-2 py-1 rounded-full text-xs font-medium ' \
      'whitespace-nowrap transition-colors'

    if saved_filter_active?(saved_filter)
      "#{base} bg-indigo-600 text-white dark:bg-indigo-500"
    else
      "#{base} bg-gray-100 text-gray-700 hover:bg-indigo-100 hover:text-indigo-800 " \
        'dark:bg-gray-800 dark:text-gray-300 dark:hover:bg-indigo-900/40'
    end
  end

  # saved_filter_id lets the operation remember the clicked preset as the user's default
  def apply_saved_filter_path(saved_filter)
    helpers.vacancies_path(saved_filter_id: saved_filter.hashid,
                           include_tags: saved_filter.include_tags,
                           include_ops:  saved_filter.include_ops,
                           exclude_tags: saved_filter.exclude_tags)
  end
end
