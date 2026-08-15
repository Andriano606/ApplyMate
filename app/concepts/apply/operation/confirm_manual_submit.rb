# frozen_string_literal: true

# Closes an assisted session after the person pressed submit themselves.
# Reads the still-open page for a success or refusal signal instead of taking
# the click on faith, then releases the browser and the CV tempfile.
class Apply::Operation::ConfirmManualSubmit < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    apply = Apply.find_by_hashid!(params[:id])
    authorize! apply, :retry?
    self.model = apply

    outcome = inspect_session(apply)

    if outcome[:refused]
      apply.update!(status: :needs_review, error: outcome[:message])
      notice(I18n.t('apply.assisted.refused'), level: :alert)
    else
      apply.update!(status: :completed, error: nil, review_fields: nil)
      notice(I18n.t('apply.assisted.confirmed'))
    end

    Apply::TurboHandler::StatusUpdate.broadcast(apply)
    release(apply)
  end

  private

  # Best effort: the user may have closed the window already, in which case we
  # trust their confirmation.
  def inspect_session(apply)
    browser = Apply::AssistedSession.fetch(apply.id)
    return { refused: false } if browser.nil?

    capture_screenshot(apply, browser)
    state  = browser.observe_state
    alerts = Array(state['alerts']).map { |t| t.to_s.squish }.reject(&:blank?)
    refusal = alerts.find { |text| text.match?(Apply::Operation::External::Generic::REJECTION_TEXT) }

    return { refused: false } if refusal.blank?

    { refused: true, message: "Сайт відхилив відправку: #{alerts.uniq.join(' — ').truncate(400)}" }
  rescue StandardError => e
    Rails.logger.warn("ConfirmManualSubmit: could not inspect session: #{e.message}")
    { refused: false }
  end

  def capture_screenshot(apply, browser)
    data = browser.screenshot
    return if data.blank?

    apply.screenshot.attach(io: StringIO.new(data), filename: "screenshot_#{apply.id}.png",
                            content_type: 'image/png')
  rescue StandardError => e
    Rails.logger.warn("ConfirmManualSubmit: screenshot failed: #{e.message}")
  end

  def release(apply)
    Apply::AssistedSession.close(apply.id)
    FileUtils.rm_f(Rails.root.join('tmp', "assisted_cv_#{apply.id}.pdf"))
  end
end
