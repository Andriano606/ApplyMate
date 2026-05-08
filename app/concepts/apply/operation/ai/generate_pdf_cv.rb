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
    raw_pdf = apply.raw_cv.presence || ApplyMate::Ai::AiHandler.call(
      prompt_instance:       prompt_class.new(apply),
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
end
