# frozen_string_literal: true

# Failure / pre-submit evidence of the open browser session, attached to the step row (design §13.2): a screenshot
# with every fillable control painted over (`<label>.png`) and, for the :failure label, the HTML of each frame made
# inert (SanitizeHtml: no scripts, frames or handlers, a CSP meta) and redacted (`<label>_f<i>.html`, at most
# HTML_LIMIT characters each; Artifact::Operation::Show serves it as a download, never inline). No-op without an open
# session or a step row, or once ApplyStep::MAX_ARTIFACTS_PER_ATTEMPT artifacts were stored this attempt. Never raises: evidence must not replace
# the error being recorded. model = number of artifacts attached.
class Apply::Operation::Engine::CaptureArtifact < ApplyMate::Operation::Base
  include ApplyMate::Logging

  HTML_LIMIT = 512.kilobytes

  def perform!(ctx:, step_record:, label:, **)
    skip_authorize
    self.model = 0
    return unless ctx.session_open? && step_record

    attach(ctx, step_record, 'image/png', "#{label}.png") { ctx.session.screenshot(mask_fillable: true) }
    capture_html(ctx, step_record, label) if label.to_sym == :failure
  end

  private

  def capture_html(ctx, step_record, label)
    ctx.session.frames.each_with_index do |frame, index|
      attach(ctx, step_record, 'text/html', "#{label}_f#{index}.html") do
        html = Apply::Operation::Engine::SanitizeHtml.call(html: ctx.session.html(frame_path: frame_path(frame, index))).model
        Apply::Operation::Engine::Redact.call(text: html, apply: ctx.apply, max_length: HTML_LIMIT).model
      end
    end
  end

  # The main frame is the top document; other frames are picked by url (Locate searches the flat frame list).
  def frame_path(frame, index)
    index.zero? ? [] : [ { 'url_contains' => frame['url'] } ]
  end

  def attach(ctx, step_record, content_type, filename)
    return if ctx.scratch.artifacts_count >= ApplyStep::MAX_ARTIFACTS_PER_ATTEMPT

    body = yield
    return if body.nil?

    step_record.artifacts.attach(io: StringIO.new(body), filename:, content_type:)
    ctx.scratch.artifacts_count += 1
    self.model += 1
  rescue StandardError => e
    log("apply=#{ctx.apply.hashid} artifact #{filename} skipped: #{e.class}: #{e.message}", level: :warn)
    Rails.error.report(e, handled: true, context: { apply: ctx.apply.hashid, artifact: filename })
  end
end
