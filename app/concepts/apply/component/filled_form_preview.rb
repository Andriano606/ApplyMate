# frozen_string_literal: true

class Apply::Component::FilledFormPreview < ApplyMate::Component::Base
  FIELD_CLASSES = 'block w-full rounded-lg border border-gray-200 bg-gray-50 px-3 py-2 text-sm text-gray-900 ' \
                  'resize-y dark:border-gray-600 dark:bg-gray-700 dark:text-gray-100'

  # vacancy: enables the per-question "generate answer" action (VacancyQuestion new modal, prefilled).
  # cv_attached: what file fields show — a native file input would always read "No file chosen".
  def initialize(filled_inputs:, vacancy: nil, cv_attached: false)
    @fields      = Apply::FormField.wrap(filled_inputs).select(&:visible?)
    @vacancy     = vacancy
    @cv_attached = cv_attached
  end

  private

  def file_label
    @cv_attached ? I18n.t('apply.card.cv_attached') : I18n.t('apply.card.cv_not_attached')
  end

  def generate_answer_path(field)
    return if @vacancy.nil? || !field.question?

    helpers.new_vacancy_vacancy_question_path(@vacancy, vacancy_question: { question: field.label })
  end
end
