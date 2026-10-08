# frozen_string_literal: true

# The current user's questions for a vacancy (newest first) plus suggested questions: the open questions
# (Apply#question_labels) of the latest apply form scraped for this vacancy that were not asked yet.
# Also called by VacancyQuestion::TurboHandler::Index.broadcast so live updates render the same data.
class VacancyQuestion::Operation::Index < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    vacancy = Vacancy.find(params[:vacancy_id])
    authorize! VacancyQuestion.new, :index?
    # Rides index_vacancy_questions_on_vacancy_id; a vacancy has a handful of questions per user.
    vacancy_questions = policy_scope(VacancyQuestion).where(vacancy:).order(created_at: :desc).to_a

    self.model = ApplyMate::Operation::Struct.new(
      vacancy:,
      vacancy_questions:,
      question_suggestions: question_suggestions(vacancy, vacancy_questions)
    )
  end

  private

  def question_suggestions(vacancy, vacancy_questions)
    asked = vacancy_questions.to_set { |vacancy_question| normalize(vacancy_question.question) }
    labels = latest_form_apply(vacancy)&.question_labels || []
    labels.uniq { |label| normalize(label) }.reject { |label| asked.include?(normalize(label)) }
  end

  # Rides index_applies_on_vacancy_id; a vacancy has a handful of applies per user.
  def latest_form_apply(vacancy)
    policy_scope(Apply).where(vacancy:).order(created_at: :desc).find { |apply| apply.fields.present? || apply.inputs.present? }
  end

  def normalize(text)
    text.to_s.strip.downcase
  end
end
