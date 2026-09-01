# frozen_string_literal: true

# One modal for both flows: a new record posts to /saved_filters, a persisted one
# patches /saved_filters/:id (simple_form picks the verb from the record).
class SavedFilter::Component::FormModal < ApplyMate::Component::Base
  def initialize(saved_filter:, **)
    @saved_filter = saved_filter
  end

  private

  def scope
    @saved_filter.persisted? ? 'edit' : 'new'
  end

  def header_text
    I18n.t("saved_filter.#{scope}.header")
  end

  def submit_text
    I18n.t("saved_filter.#{scope}.submit")
  end
end
