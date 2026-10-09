# frozen_string_literal: true

# Writes the answers into the form (design §7.2, §7.4), before the submit claim, page by page (a wizard has several):
#
#   page 1      the fields on the page in this session (ctx.fields with a target: ReconcileFields keeps the stored
#               fields of later wizard pages without one), in platform.fill_order
#   each page   every fillable field with an answer in applies.answers goes through Engine::SetFieldValue (widget write,
#               read-back, fallback); a field filled on an earlier page is never filled again. Then review!
#               (Answer::ReviewRequired -> Halt(:review): before any Next click and before the claim), then
#               Engine::ClassifyAdvance:
#                 nil     -> Halt(:target_not_found, detail: 'no submit or next button in the form')
#                 :final  -> every required field of ctx.fields must have been on a page of this session, else
#                            Halt(:target_not_found, detail: id); return (Stage::Submit clicks the :final button after
#                            the claim)
#                 :next   -> on page MAX_WIZARD_PAGES: Halt(:wizard_too_long, detail: "more than 6 pages"); else
#                            GuardAction { click }, ctx.scratch.wizard_page = the new page, settle(:click),
#                            RunGates(:after_action) on a fresh form snapshot, Engine::AnswerFollowups (new fields answered: <= one AI call per page, capped) gives the
#                            next page's fields; traced `wizard_page`
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

  private

  def run!(ctx:, apply:, **)
    @filled = []
    @unfilled = []
    page_fields = ctx.platform.fill_order(Array(ctx.fields).select(&:target))
    (1..MAX_WIZARD_PAGES).each do |page|
      fill_page(ctx, apply, page_fields)
      review!(ctx)
      advance = Apply::Operation::Engine::ClassifyAdvance.call(ctx:).model
      halt!(:target_not_found, detail: 'no submit or next button in the form') if advance.nil?
      return finish!(ctx, page) if advance.kind == :final

      halt!(:wizard_too_long, detail: "more than #{MAX_WIZARD_PAGES} pages") if page == MAX_WIZARD_PAGES
      page_fields = next_page!(ctx, advance, page + 1)
    end
  end

  def fill_page(ctx, apply, fields)
    fields.each do |field|
      next unless field.fillable?
      next if @filled.include?(field.id) || @unfilled.include?(field.id)

      outcome = fill(ctx, apply, field)
      (outcome ? @filled : @unfilled) << field.id unless outcome.nil?
    end
  end

  def next_page!(ctx, advance, page)
    session = ctx.session
    Apply::Operation::Engine::GuardAction.call(ctx:, action: -> { session.click(advance.target) })
    ctx.scratch.wizard_page = page
    session.settle(:click)
    snapshot = Apply::Operation::Engine::FormElements.snapshot(ctx)
    Apply::Operation::Engine::RunGates.call(ctx:, event: :after_action, snapshot:)
    fields = Apply::Operation::Engine::AnswerFollowups.call(ctx:, page:, snapshot:).model
    ctx.trace(:wizard_page, page:, button: advance.name, fields: fields.size)
    fields
  end

  # A required field of a later page that this session never showed: the wizard changed under the stored answers.
  def finish!(ctx, pages)
    absent = Array(ctx.fields).find { |field| field.required && field.fillable? && field.target.nil? && @filled.exclude?(field.id) }
    halt!(:target_not_found, detail: absent.id) if absent

    step_result(filled: @filled.size, unfilled: @unfilled, pages:)
  end

  # true filled, false unfilled (optional mismatch), nil nothing to write (optional, no answer).
  def fill(ctx, apply, field)
    value = value_for(apply, field)
    if value.nil?
      halt!(:required_field_unfillable, detail: field.id) if field.required
      return
    end

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
