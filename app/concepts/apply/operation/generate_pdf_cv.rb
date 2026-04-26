# frozen_string_literal: true

class Apply::Operation::GeneratePdfCv < ApplyMate::Operation::Base
  FILENAME = 'Andrii_Kuluiev_Senior_Rails_Developer.pdf'

  def perform!(apply_id:, **)
    self.model = Apply.includes(:vacancy, :user_profile, :ai_integration).find(apply_id)

    markdown = ask_ai_generate_markdown_cv
    raw_pdf = convert_markdown_to_pdf(markdown)

    update_apply(raw_pdf)
  end

  private

  def update_apply(raw_pdf)
    model.cv.attach(
      io: StringIO.new(raw_pdf),
      filename: FILENAME,
      content_type: 'application/pdf'
    )
    model.error = nil
    model.status = :cv_generated
    model.save!

    broadcast
  end

  def convert_markdown_to_pdf(markdown)
    convert_result = run_operation ApplyMate::Operation::ConvertMarkdownToPdf, { markdown: }
    if convert_result.failure?
      model.update!(status: :failed_cv_generation, error: convert_result.all_error_messages.join(', '))
      broadcast
      raise RecordInvalid, convert_result.all_error_messages.join(', ')
    end

    convert_result.model
  end

  def ask_ai_generate_markdown_cv
    return model.cv_markdown unless model.cv_markdown.nil?

    model.update!(status: :generating_cv)
    broadcast

    generate_result = run_operation Apply::Operation::GenerateMarkdownCv, { apply: model }
    if generate_result.failure?
      model.update!(status: :failed_cv_generation, error: generate_result.all_error_messages.join(', '))
      broadcast
      raise RecordInvalid, generate_result.all_error_messages.join(', ')
    end

    generate_result.model.cv_markdown
  end

  def broadcast
    Apply::TurboHandler::StatusUpdate.broadcast(model)
  end
end
