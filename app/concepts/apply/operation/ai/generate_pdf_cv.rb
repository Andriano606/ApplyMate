# frozen_string_literal: true

class Apply::Operation::Ai::GeneratePdfCv < Apply::Operation::Base
  def start_status
    :generating_cv
  end

  def error_status
    :failed_generating_cv
  end

  private

  def run!(apply:, handler:, prompt_class:, schema_class:, **)
    # Status is already generating_cv: the vacancy page CV list shows a "generating during apply" placeholder.
    VacancyCv::TurboHandler::Index.broadcast_row(apply)

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
    apply.update!(error: nil)
  end

  # Runs after Base has stored the final status (failure included): the placeholder becomes the CV or disappears.
  def cleanup
    VacancyCv::TurboHandler::Index.broadcast_row(model)
  end
end
