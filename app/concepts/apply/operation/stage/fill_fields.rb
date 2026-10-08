# frozen_string_literal: true

# Writes the answers into the form (design §7.2, §7.4), before the submit claim. In platform.fill_order (Ashby:
# files first), every fillable field with an answer in applies.answers goes through Engine::SetFieldValue (widget
# write, read-back, fallback). A file answer ({ 'file' => 'cv' }) uploads the apply's CV, written once into a temp
# directory under its own file name (removed in cleanup).
#
#   required field without an answer (or without a CV)  -> Halt(:required_field_unfillable, detail: id)
#   Apply::Widget::Mismatch                              -> the same halt when required, else traced `unfilled`
#   Answer::ReviewRequired afterwards                    -> Halt(:review) (still before the claim)
#   no submit button inside the form root afterwards     -> Halt(:wizard_too_long, detail: 'multi-page form'):
#                                                           wizards arrive in phase 3b
class Apply::Operation::Stage::FillFields < Apply::Operation::Stage::Base
  stage :fill

  private

  def run!(ctx:, apply:, **)
    filled = []
    unfilled = []
    ctx.platform.fill_order(Array(ctx.fields)).each do |field|
      next unless field.fillable?

      outcome = fill(ctx, apply, field)
      (outcome ? filled : unfilled) << field.id unless outcome.nil?
    end
    review!(ctx)
    submit_button!(ctx)
    step_result(filled: filled.size, unfilled:)
  end

  # true filled, false unfilled (optional mismatch), nil nothing to write (optional, no answer).
  def fill(ctx, apply, field)
    value = value_for(apply, field)
    if value.nil?
      halt!(:required_field_unfillable, detail: field.id) if field.required
      return
    end

    Apply::Operation::Engine::SetFieldValue.call(ctx:, field:, value:)
    true
  rescue Apply::Widget::Mismatch
    halt!(:required_field_unfillable, detail: field.id) if field.required
    ctx.trace(:unfilled, field: field.id, widget: field.widget)
    false
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

  def submit_button!(ctx)
    snapshot = Apply::Operation::Engine::FormElements.snapshot(ctx)
    elements = Apply::Operation::Engine::FormElements.call(ctx:, snapshot:).model
    halt!(:wizard_too_long, detail: 'multi-page form') if elements.none? { |element| element['submit_like'] }
  end

  def cleanup
    FileUtils.remove_entry(@cv_dir) if @cv_dir
  end
end
