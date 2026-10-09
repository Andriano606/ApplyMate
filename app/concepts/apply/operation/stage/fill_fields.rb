# frozen_string_literal: true

# Writes the answers into the form (design §7.2, §7.4), before the submit claim, page by page (a wizard has several):
#
#   page 1      the fields on the page in this session (ctx.fields with a target: ReconcileFields keeps the stored
#               fields of later wizard pages without one), in platform.fill_order
#   each page   every fillable field with an answer in applies.answers goes through Engine::SetFieldValue (widget write,
#               read-back, fallback); a field filled on an earlier page is never filled again. A field that is in the
#               DOM but not shown (Session#present?(visibility: :required): a CSS-hidden later wizard step, a
#               display:none honeypot, an unrevealed conditional) is skipped on this page and offered again on the
#               next one (AnswerFollowups lists every field present in the DOM); a file input is exempt (clipped by
#               design, uploaded while hidden). Then review!
#               (Answer::ReviewRequired -> Halt(:review): before any Next click and before the claim), then
#               Engine::ClassifyAdvance on a fresh form snapshot (also the page's key, see below):
#                 nil     -> Halt(:target_not_found, detail: 'no submit or next button in the form')
#                 :final  -> every required field of ctx.fields must have been on a page of this session, else
#                            Halt(:target_not_found, detail: id), and shown, else the unfilled-required halt
#                            (CaptureArtifact :unfillable, Halt(:required_field_unfillable, detail: id)); optional
#                            never-shown ones are traced `hidden_unfilled`; return (Stage::Submit clicks the :final button after
#                            the claim)
#                 :next   -> on page MAX_WIZARD_PAGES: Halt(:wizard_too_long, detail: "more than 6 pages"); else
#                            GuardAction { click }, ctx.scratch.wizard_page = the new page, settle(:click),
#                            RunGates(:after_action) on a fresh form snapshot, Engine::AnswerFollowups (new fields answered: <= one AI call per page, capped) gives the
#                            next page's fields; traced `wizard_page`
#
# A Next that does not advance: after the click the page key (the form frame's URL, SnapshotAll.digest_of the form's
# elements - the Navigator's ONE page-state digest - and the frame outline without `dialog` lines) is compared with the
# key before it. Still the same after one more settle(:click) -> the site refused the page (a JS or server check the
# read-back never sees: "email already registered", a custom error without aria-invalid) -> traced `wizard_stalled`,
# Halt(:validation_rejected, detail: "next did not advance: <form-frame alerts | invalid: <field name>>",
# MAX_STALL_DETAIL), before any claim - never the same Next clicked again until wizard_too_long. A key that changes
# only by a validation dialog or toast button falls back to the page cap below.
#
# A file answer ({ 'file' => 'cv' }) uploads the apply's CV, written once into a temp directory under its own file name
# (removed in cleanup).
#
#   required field without an answer (or without a CV)  -> Halt(:required_field_unfillable, detail: id)
#   Apply::Widget::Mismatch                              -> Engine::RecoverField (<= 2 AI click / press micro-turns,
#                                                           any AI integration)
#   still a Mismatch                                     -> required: a masked `unfillable` screenshot on the step row,
#                                                           then the same halt; optional: traced `unfilled`
#   an approximate pick (Autocomplete's first suggestion) -> the answer becomes { value: <label>, source:
#                                                           'approximate', confidence: 0.5 }, persisted at once
#
# Termination: at most MAX_WIZARD_PAGES pages (one Next click each, at most MAX_WIZARD_PAGES - 1 clicks), every page's
# fields are finite, AnswerFollowups caps its answer calls. After an approved review the submit scope replays the pages
# from the stored answers (the follow-up fields keep their ids, so nothing is asked again).
#
# step_result { filled: n, unfilled: [ids], pages: n }
class Apply::Operation::Stage::FillFields < Apply::Operation::Stage::Base
  stage :fill

  APPROXIMATE_CONFIDENCE = 0.5
  MAX_WIZARD_PAGES = 6
  MAX_STALL_DETAIL = 300

  private

  def run!(ctx:, apply:, **)
    @filled = []
    @unfilled = []
    @hidden = Set.new
    page_fields = ctx.platform.fill_order(Array(ctx.fields).select(&:target))
    (1..MAX_WIZARD_PAGES).each do |page|
      fill_page(ctx, apply, page_fields)
      review!(ctx)
      snapshot = Apply::Operation::Engine::FormElements.snapshot(ctx)
      advance = Apply::Operation::Engine::ClassifyAdvance.call(ctx:, snapshot:).model
      halt!(:target_not_found, detail: 'no submit or next button in the form') if advance.nil?
      return finish!(ctx, page) if advance.kind == :final

      halt!(:wizard_too_long, detail: "more than #{MAX_WIZARD_PAGES} pages") if page == MAX_WIZARD_PAGES
      page_fields = next_page!(ctx, advance, page + 1, page_key(ctx, snapshot))
    end
  end

  def fill_page(ctx, apply, fields)
    fields.each do |field|
      next unless field.fillable?
      next if @filled.include?(field.id) || @unfilled.include?(field.id)
      @hidden.delete(field.id)
      outcome = fill(ctx, apply, field)
      next if outcome.nil?

      { true => @filled, false => @unfilled, hidden: @hidden }.fetch(outcome) << field.id
    end
  end

  def shown?(ctx, field)
    field.file? || ctx.session.present?(field.target, visibility: :required)
  end

  def next_page!(ctx, advance, page, before)
    session = ctx.session
    Apply::Operation::Engine::GuardAction.call(ctx:, action: -> { session.click(advance.target) })
    ctx.scratch.wizard_page = page
    session.settle(:click)
    snapshot = advanced_snapshot(ctx, advance, page, before)
    Apply::Operation::Engine::RunGates.call(ctx:, event: :after_action, snapshot:)
    fields = Apply::Operation::Engine::AnswerFollowups.call(ctx:, page:, snapshot:).model
    ctx.trace(:wizard_page, page:, button: advance.name, fields: fields.size)
    fields
  end

  # A required field of a later page that this session never showed: the wizard changed under the stored answers.
  # The form after the Next click; one more settle when it still has the key it had before (a slow transition), then
  # the stall halt (see the header). Bounded: two snapshots at most.
  def advanced_snapshot(ctx, advance, page, before)
    snapshot = Apply::Operation::Engine::FormElements.snapshot(ctx)
    return snapshot unless page_key(ctx, snapshot) == before

    ctx.session.settle(:click)
    snapshot = Apply::Operation::Engine::FormElements.snapshot(ctx)
    return snapshot unless page_key(ctx, snapshot) == before

    ctx.trace(:wizard_stalled, page: page - 1, button: advance.name)
    halt!(:validation_rejected, detail: stall_detail(ctx, snapshot))
  end

  def page_key(ctx, snapshot)
    frame = form_frame(ctx, snapshot)
    elements = Apply::Operation::Engine::FormElements.call(ctx:, snapshot:).model
    [ frame&.fetch('url', nil), ApplyMate::Client::Browser::Operation::SnapshotAll.digest_of(elements),
      Array(frame&.fetch('outline', nil)).grep_v(/\Adialog /) ]
  end

  def stall_detail(ctx, snapshot)
    invalid = Apply::Operation::Engine::FormElements.call(ctx:, snapshot:).model.select { |element| element['invalid'] }
    said = [ *Array(form_frame(ctx, snapshot)&.fetch('alerts', nil)), *invalid.map { |element| "invalid: #{element['name']}" } ]
    [ 'next did not advance', said.join(' | ').squish.presence ].compact.join(': ').truncate(MAX_STALL_DETAIL)
  end

  def form_frame(ctx, snapshot)
    frame_path = ctx.form_root&.frame_path || []
    snapshot.frames.find { |frame| frame['frame_path'] == frame_path }
  end

  def finish!(ctx, pages)
    missing = Array(ctx.fields).select { |field| field.required && field.fillable? && @filled.exclude?(field.id) }
    absent = missing.find { |field| field.target.nil? }
    halt!(:target_not_found, detail: absent.id) if absent
    never_shown = missing.find { |field| @hidden.include?(field.id) }
    unfillable!(ctx, never_shown) if never_shown
    ctx.trace(:hidden_unfilled, fields: @hidden.to_a) if @hidden.any?

    step_result(filled: @filled.size, unfilled: @unfilled, pages:)
  end

  # true filled, false unfilled (optional mismatch), nil nothing to write (optional, no answer), :hidden not shown on
  # this page (offered again on the next one).
  def fill(ctx, apply, field)
    value = value_for(apply, field)
    if value.nil?
      halt!(:required_field_unfillable, detail: field.id) if field.required
      return
    end
    return :hidden unless shown?(ctx, field)

    approximate!(ctx, apply, field, set_value(ctx, field, value)[:approximate])
    true
  rescue Apply::Widget::Mismatch
    unfillable!(ctx, field) if field.required
    ctx.trace(:unfilled, field: field.id, widget: field.widget)
    false
  end

  def set_value(ctx, field, value)
    Apply::Operation::Engine::SetFieldValue.call(ctx:, field:, value:)
  rescue Apply::Widget::Mismatch => e
    Apply::Operation::Engine::RecoverField.call(ctx:, field:, value:, mismatch: e)
  end

  # Persisted at once (not buffered until after the loop): a later field's halt must not lose it.
  def approximate!(ctx, apply, field, label)
    return if label.nil?

    ctx.trace(:approximate_pick, field: field.id, widget: field.widget)
    entry = { 'value' => label, 'source' => 'approximate', 'confidence' => APPROXIMATE_CONFIDENCE }
    ctx.persist!(answers: (apply.answers || {}).merge(field.id => entry))
  end

  def unfillable!(ctx, field)
    Apply::Operation::Engine::CaptureArtifact.call(ctx:, step_record: ctx.scratch.step_record, label: :unfillable)
    halt!(:required_field_unfillable, detail: field.id)
  end

  # The answer in widget terms, or nil when there is nothing to write (no answer, a blank one, a file that does not
  # exist). false stays false: an explicit "unticked". A file field uploads only the apply's own file (FileRef): any
  # other answer (an AI or review string) would be a local path to upload, so it is nothing.
  def value_for(apply, field)
    value = apply.answer_for(field.id)&.fetch('value', nil)
    file = Apply::Operation::Answer::FileRef.parse(value)
    return cv_path(apply) if file&.cv?
    return if file || field.file? || value.nil? || (value.respond_to?(:empty?) && value.empty?)

    value
  end

  def cv_path(apply)
    return unless apply.cv.attached?

    @cv_path ||= begin
      @cv_dir = Dir.mktmpdir('apply-cv')
      path = File.join(@cv_dir, apply.cv.filename.sanitized.presence || 'CV.pdf')
      File.open(path, 'wb') { |file| apply.cv.download { |chunk| file.write(chunk) } }
      path
    end
  end

  def review!(ctx)
    required = Apply::Operation::Answer::ReviewRequired.call(ctx:)
    halt!(:review, detail: required[:reasons].join(',')) if required.model
  end

  def cleanup
    FileUtils.remove_entry(@cv_dir) if @cv_dir
  end
end
