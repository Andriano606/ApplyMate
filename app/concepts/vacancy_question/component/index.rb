# frozen_string_literal: true

class VacancyQuestion::Component::Index < ApplyMate::Component::Base
  LAZY = :lazy
  SUGGESTIONS_CLASSES = 'rounded-xl border border-indigo-100 bg-indigo-50 p-4 ' \
                        'dark:border-indigo-900/50 dark:bg-indigo-900/20'

  # question_suggestions: open questions of the latest scraped apply form not asked yet (Array<String>).
  def initialize(vacancy:, vacancy_questions:, question_suggestions: [], user: LAZY, **)
    @vacancy              = vacancy
    @vacancy_questions    = vacancy_questions
    @question_suggestions = question_suggestions
    @user_preset          = user
  end

  def before_render
    @page_user = @user_preset == LAZY ? current_user : @user_preset
  end

  private

  def page_user
    @page_user
  end

  def new_question_path(question = nil)
    return helpers.new_vacancy_vacancy_question_path(@vacancy) if question.nil?

    helpers.new_vacancy_vacancy_question_path(@vacancy, vacancy_question: { question: })
  end
end
