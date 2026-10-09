# frozen_string_literal: true

class VacancyCv::Job::Create < ApplicationJob
  queue_as :apply

  # One AI call + Grover. The key prefix follows VacancyCv's own id space: reusing `apply:<id>`
  # would serialise unrelated records that happen to share an integer.
  limits_concurrency to: 1, key: ->(vacancy_cv_id, _user_id) { "vacancy_cv:#{vacancy_cv_id}" }, duration: 15.minutes

  # The process-wide local Chrome slot (GeminiScraping's call, another job's Grover render) stayed taken for the whole
  # wait: a few spaced retries, then the job fails like any other generation error.
  retry_on ApplyMate::Client::LocalChrome::Busy, attempts: 3, wait: :polynomially_longer

  def perform(vacancy_cv_id, user_id)
    vacancy_cv = VacancyCv.includes(:ai_integration, :user_profile, :generate_cv_prompt, :vacancy).find(vacancy_cv_id)
    vacancy    = vacancy_cv.vacancy

    raw_pdf = ApplyMate::Ai::AiHandler.call(
      prompt_instance:       Apply::Ai::Prompt::GenerateCv.new(
                               user_profile:       vacancy_cv.user_profile,
                               vacancy:            vacancy,
                               generate_cv_prompt: vacancy_cv.generate_cv_prompt
                             ),
      response_schema_class: Apply::Ai::ResponseSchema::GenerateCv,
      ai_integration:        vacancy_cv.ai_integration
    )

    vacancy_cv.cv.attach(
      io:           StringIO.new(raw_pdf),
      filename:     vacancy_cv.cv_filename,
      content_type: 'application/pdf'
    )
    VacancyCv::TurboHandler::CvReady.broadcast(vacancy_cv)
  end
end
