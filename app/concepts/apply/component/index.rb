# frozen_string_literal: true

class Apply::Component::Index < ApplyMate::Component::Base
  def initialize(applies:, filter: nil, attention_count: 0, **)
    @applies = applies
    @filter = filter
    @attention_count = attention_count
  end

  private

  def header_opts
    { title: I18n.t('apply.index.title') }
  end

  def filter_tabs
    [
      { label: I18n.t('apply.index.filter.all'), url: helpers.applies_path, active: @filter.blank? },
      { label: I18n.t('apply.index.filter.attention', count: @attention_count),
        url: helpers.applies_path(filter: 'attention'), active: @filter == 'attention' }
    ]
  end

  def tab_class(active)
    style = active ? ApplyMate::Component::Tabs::TAB_ACTIVE : ApplyMate::Component::Tabs::TAB_INACTIVE
    "#{ApplyMate::Component::Tabs::TAB_BASE} #{style}"
  end
end
