# frozen_string_literal: true

# Assisted mode: opens a browser the user can see, fills the whole form with the
# answers already resolved for this apply (including the generated CV, which is
# the tedious part to do by hand) and stops. The person reviews the form and
# presses submit themselves.
#
# This is the answer to forms automation cannot finish — a site that refuses
# robot submissions, a captcha, a wizard we could not drive. A human submits, so
# nothing is worked around; the app just does the typing.
#
# The browser session deliberately outlives this operation (see AssistedSession).
class Apply::Operation::AssistedFill < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    apply = Apply.find_by_hashid!(params[:id])
    authorize! apply, :retry?
    self.model = apply

    raise I18n.t('apply.assisted.errors.no_answers') if apply.filled_inputs.blank?

    browser = open_session(apply)
    fill_form(apply, browser)

    apply.update!(status: :awaiting_manual_submit, error: nil)
    Apply::TurboHandler::StatusUpdate.broadcast(apply)

    notice(I18n.t('apply.assisted.opened'))
  rescue StandardError => e
    Apply::AssistedSession.close(apply&.id) if defined?(apply) && apply
    add_error(:base, e.message)
    raise
  end

  private

  # A visible browser: the shared chrome_vnc instance when configured (the user
  # watches it through noVNC), otherwise a real window next to the app.
  def open_session(apply)
    browser = ApplyMate::Client::Browser.new(headless: false, shared: true)
    Apply::AssistedSession.store(apply.id, browser.detach)
    browser
  end

  def fill_form(apply, browser)
    browser.navigate_to(apply.resolved_url.presence || apply.external_url)
    browser.wait_for_fields

    follow_embedded_form(browser)

    snapshot = browser.snapshot_fields
    fields   = Array(snapshot['fields'])
    raise I18n.t('apply.assisted.errors.no_form') if fields.empty?

    inputs = Apply::FormFiller.remap(apply.filled_inputs, enrich(fields))
    Apply::FormFiller.new(browser:, cv_path: cv_path(apply)).fill(inputs)
  end

  def follow_embedded_form(browser)
    return if browser.field_count.positive?

    embedded = Apply::EmbeddedForm.locate(browser.iframe_sources)
    return if embedded.blank?

    browser.navigate_to(embedded)
    browser.wait_for_fields
  end

  def enrich(fields)
    fields.map do |field|
      field = field.to_h.stringify_keys
      field.merge('fingerprint' => field['fingerprint'].presence || Apply::FieldFingerprint.call(field))
    end
  end

  # The CV file must survive the request — the tempfile is unlinked only when
  # the assisted session is closed, so keep it on disk under tmp/.
  def cv_path(apply)
    return nil unless apply.cv.attached?

    path = Rails.root.join('tmp', "assisted_cv_#{apply.id}.pdf")
    File.open(path, 'wb') { |file| apply.cv.download { |chunk| file.write(chunk) } }
    path.to_s
  end
end
