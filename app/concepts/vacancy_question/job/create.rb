# frozen_string_literal: true

class VacancyQuestion::Job::Create < ApplicationJob
  queue_as :default

  def perform(vacancy_question_id)
    vacancy_question = VacancyQuestion.includes(:ai_integration, :user_profile, :fill_form_prompt, :vacancy)
                                      .find(vacancy_question_id)

    answer = ApplyMate::Ai::AiHandler.call(
      prompt_instance:       VacancyQuestion::Ai::Prompt::AnswerQuestion.new(vacancy_question),
      response_schema_class: VacancyQuestion::Ai::ResponseSchema::AnswerQuestion,
      ai_integration:        vacancy_question.ai_integration
    )

    vacancy_question.update!(answer:)
    VacancyQuestion::TurboHandler::AnswerReady.broadcast(vacancy_question)
  end
end
