# frozen_string_literal: true

# What the page shows after the submit click (design §11.4), for VerifySubmit. Read-only:
#
#   text          the text of the form root (ctx.form_root's selector in its frame), or of the frame's body when the
#                 root is gone (the element that replaced it), squished, at most TEXT_LIMIT characters
#   urls          the session's URL and every frame URL
#   requests      non-GET requests since the claim (ctx.scratch.claim_mark), with the bodies of watched URLs
#                 (NetTracker#since(bodies: true); the submit_request URL was watched before the click)
#   in_flight     non-GET requests since the claim that have not ended yet (NetTracker#in_flight_since; `requests`
#                 lists only ended ones). Read BEFORE `requests`, so a request ending in between is counted twice,
#                 never missed.
#   form_present  the form root is still there and still holds controls
#   field_errors  { field id => error text or 'invalid' } of known fields whose read-back is invalid (aria-invalid or
#                 :invalid). An error text alone is not enough: read_value.js gathers every live region and
#                 aria-describedby node of the field, which also holds hints and upload notices ("CV.pdf uploaded").
#                 Only while the form is present; at most MAX_FIELD_PROBES fields probed.
#
# model = Evidence
class Apply::Operation::Engine::CollectSubmitEvidence < ApplyMate::Operation::Base
  Evidence = Data.define(:text, :urls, :requests, :in_flight, :form_present, :field_errors)

  TEXT_LIMIT = 4_000
  MAX_FIELD_PROBES = 50
  CONTROLS = 'input:not([type=hidden]), textarea, select'
  # Text nodes a reader sees: one space between nodes (block elements must not glue words), no script/style bodies.
  VISIBLE_TEXT = './/text()[not(ancestor::script or ancestor::style or ancestor::noscript or ancestor::template)]'

  # field_errors: false skips the per-field read_value probes (VerifySubmit's polling needs only the signals).
  def perform!(ctx:, field_errors: true, **)
    skip_authorize
    session = ctx.session
    root = form_root(ctx, session)
    form_present = root.present? && root.css(CONTROLS).any?
    mark = ctx.scratch.claim_mark
    in_flight = mark.nil? ? 0 : session.network_in_flight(mark)
    self.model = Evidence.new(
      text: text_of(root || @document.at('body') || @document),
      urls: [ session.current_url, *session.frames.pluck('url') ].compact_blank.uniq,
      requests: mark.nil? ? [] : session.network_since(mark, bodies: true), in_flight:, form_present:,
      field_errors: form_present && field_errors ? field_errors(ctx, session) : {}
    )
  end

  private

  def text_of(node)
    node.xpath(VISIBLE_TEXT).map(&:text).join(' ').squish.first(TEXT_LIMIT)
  end

  # The form root element in the parsed frame HTML (Nokogiri), or nil when it is gone.
  def form_root(ctx, session)
    frame_path = ctx.form_root&.frame_path || []
    @document = Nokogiri::HTML(session.html(frame_path:).to_s)
    selector = Apply::Operation::Engine::FormElements.root_selector(ctx)
    selector.present? ? @document.at_css(selector) : nil
  rescue ApplyMate::Client::Browser::TargetNotFound
    @document = Nokogiri::HTML('')
    nil
  end

  def field_errors(ctx, session)
    Array(ctx.fields).select(&:target).first(MAX_FIELD_PROBES).each_with_object({}) do |field, errors|
      read = session.probe(:read_value, field.target)
      errors[field.id] = read['error_text'].presence || 'invalid' if read['invalid']
    rescue ApplyMate::Client::Browser::TargetNotFound
      next
    end
  end
end
