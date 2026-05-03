# frozen_string_literal: true

class Apply::Operation::Ai::GeneratePdfCv < ApplyMate::Operation::Base
  FILENAME = 'Andrii_Kuluiev_Senior_Rails_Developer.pdf'

  def perform!(apply_id:, **)
    self.model = Apply.includes(:vacancy, :user_profile, :ai_integration).find(apply_id)

    return if model.error.present?

    raw_pdf = send_ai_request

    update_apply(raw_pdf)
  rescue StandardError => e
    model.update!(status: :failed_cv_generation, error: e.message)
    broadcast
    raise
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

  def send_ai_request
    return model.raw_cv unless model.raw_cv.nil?

    model.update!(status: :generating_cv)
    broadcast

    ApplyMate::Ai::AiHandler.call(
      prompt_instance: Apply::Ai::Prompt::Djinni::GenerateCv.new(model),
      response_schema_class: Apply::Ai::ResponseSchema::Djinni::GenerateCv,
      ai_integration: model.ai_integration
    )
  end

  def broadcast
    Apply::TurboHandler::StatusUpdate.broadcast(model.vacancy)
  end
end
