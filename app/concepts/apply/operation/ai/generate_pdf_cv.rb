# frozen_string_literal: true

class Apply::Operation::Ai::GeneratePdfCv < Apply::Operation::Base
  stage :generate_cv # Apply.with_cv_or_generating_cv lists a running apply in this stage as a CV placeholder

  private

  def run!(apply:, handler:, prompt_class:, schema_class:, **)
    # applies.stage is already generate_cv (Runner): the vacancy page CV list shows a "generating during apply"
    # placeholder.
    VacancyCv::TurboHandler::Index.broadcast(apply.vacancy, apply.user)

    raw_pdf = apply.raw_cv.presence || ApplyMate::Ai::AiHandler.call(
      prompt_instance:       prompt_class.new(user_profile: apply.user_profile, vacancy: apply.vacancy, generate_cv_prompt: apply.generate_cv_prompt),
      response_schema_class: schema_class,
      ai_integration:        apply.ai_integration
    )

    apply.cv.attach(
      io:           StringIO.new(raw_pdf),
      filename:     handler.cv_filename,
      content_type: 'application/pdf'
    )
  end

  # The placeholder becomes the CV, or disappears when the step failed: the Runner records the halt (and clears
  # applies.stage) only after this cleanup, so the row is removed explicitly instead of re-rendered from the DB.
  def cleanup
    VacancyCv::TurboHandler::Index.broadcast_row(model, leaving: !model.cv.attached?)
  end
end
