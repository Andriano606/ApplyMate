# frozen_string_literal: true

# Which button moves the form on, and is it the irreversible one (design §7.4, `Engine::SubmitLocator.classify`)? The
# ONE submit / next locator: Stage::FillFields (wizard loop) and Stage::Submit (the button behind the claim).
#
# Candidates: visible, enabled elements of the form (Engine::FormElements) that are submit_like (probe/snapshot.js), plus
# - only when the page shows evidence of a further page - buttons named by NEXT_LEXICON (a wizard's Next is often a
# type=button, which the probe never calls submit_like).
#
#   no candidate          -> model nil (the caller halts target_not_found)
#   one candidate         -> it
#   several               -> the one NEXT_LEXICON names, when the page shows evidence of a further page; else the one
#                            FINAL_LEXICON names; else Halt(:target_not_found, detail: "submit buttons in the form: n")
#
# kind :next ONLY when the chosen button's name matches NEXT_LEXICON AND the page shows evidence of a further page:
#   - a step indicator in the form root's visible text or its frame's outline (STEP_INDICATOR "Step 1 of 2" /
#     "Крок 1 з 3" with k < n), or a progressbar short of its maximum (snapshot.js outline "progressbar <now>/<max>").
#     Indicators that disagree (one of them already says the last step: a wizard that keeps every step in the DOM and
#     hides the others by CSS) are no evidence: the doubt goes to :final;
#   - a required, unconditional field of the platform schema (ctx.schema) that is still AHEAD: no ctx.fields entry at
#     all (never seen), or a stored follow-up field without a target whose page is after the current one
#     (ctx.scratch.wizard_page; a replay after an approved review). A field of an earlier page has lost its target
#     (ReconcileFields strict: false) but is behind, never evidence; a conditional one may simply be unrevealed.
# Anything else is :final and goes through Stage::Submit's claim: a click that might submit is never taken as a Next.
# The evidence is looked for only when some form button carries a NEXT_LEXICON name (one HTML read of the frame).
#
# model = Advance | nil; traced `advance` (kind, name, evidence).
class Apply::Operation::Engine::ClassifyAdvance < ApplyMate::Operation::Base
  Advance = Data.define(:kind, :target, :name)

  # \p{L}* after "наступн": the stem of наступний / наступна / наступне (\b alone would need the bare stem).
  NEXT_LEXICON = /\A\s*(?:next|continue|далі|продовжити|наступн\p{L}*|далее|weiter)\b/i
  FINAL_LEXICON = /submit|apply|send|надіслати|відправити|подати|отправить/i
  STEP_INDICATOR = %r{\b(?:step|крок|шаг|page|сторінка)\s*(\d+)\s*(?:of|з|из|/|від)\s*(\d+)}i
  PROGRESSBAR = %r{\Aprogressbar (\d+(?:\.\d+)?)/(\d+(?:\.\d+)?)\z}
  BUTTON_INPUT_TYPES = %w[submit button image].freeze

  def perform!(ctx:, snapshot: nil, **)
    skip_authorize
    @ctx = ctx
    @snapshot = snapshot || Apply::Operation::Engine::FormElements.snapshot(ctx)
    @buttons = Apply::Operation::Engine::FormElements.call(ctx:, snapshot: @snapshot).model.select do |element|
      element['visible'] && !element['disabled']
    end
    candidates = @buttons.select { |element| element['submit_like'] || (next_button?(element) && more_pages?) }
    self.model = candidates.empty? ? nil : advance(pick(candidates))
  end

  private

  attr_reader :ctx

  def advance(button)
    name = button['name'].to_s
    kind = next_name?(name) && more_pages? ? :next : :final
    ctx.trace(:advance, kind: kind.to_s, name:, evidence:)
    Advance.new(kind:, target: button['target'], name:)
  end

  def pick(candidates)
    return candidates.first if candidates.one?

    nexts = candidates.select { |element| next_name?(element['name']) }
    return nexts.first if nexts.one? && more_pages?

    finals = candidates.select { |element| element['name'].to_s.match?(FINAL_LEXICON) }
    return finals.first if finals.one?

    raise Apply::Operation::Engine::Halt.new(:target_not_found, detail: "submit buttons in the form: #{candidates.size}")
  end

  def next_name?(name)
    name.to_s.match?(NEXT_LEXICON)
  end

  # A button (not an answer button of an option group) named like a Next.
  def next_button?(element)
    button = element['tag'] == 'button' || element['role'] == 'button' ||
             (element['tag'] == 'input' && BUTTON_INPUT_TYPES.include?(element['type']))
    button && element['group'].nil? && next_name?(element['name'])
  end

  # Looked up only when a button is named like a Next: the step indicator needs one HTML read of the frame.
  def more_pages?
    return @more_pages unless @more_pages.nil?

    @more_pages = @buttons.any? { |element| next_name?(element['name']) } && evidence.any?
  end

  # ['step 1/2', 'progressbar 1/3', 'schema field missing: <id>']: what says the form has a further page.
  def evidence
    return [] unless @buttons.any? { |element| next_name?(element['name']) }

    @evidence ||= [ *step_indicators, *progress, *missing_schema_fields ]
  end

  # No evidence when any indicator already shows the last step (k >= n): with indicators that disagree the doubt must
  # end at :final (the claim), never at an unclaimed click on what may be the real submit.
  def step_indicators
    texts = [ *frame_outline, Apply::Operation::Engine::FormElements.visible_text(ctx) ]
    steps = texts.flat_map { |text| text.to_s.scan(STEP_INDICATOR) }.map { |step, total| [ step.to_i, total.to_i ] }
    steps = steps.select { |step, total| step.positive? && total.positive? }.uniq
    return [] if steps.any? { |step, total| step >= total }

    steps.map { |step, total| "step #{step}/#{total}" }
  end

  def progress
    frame_outline.filter_map do |line|
      now, max = line.match(PROGRESSBAR)&.captures&.map(&:to_f)
      line if now && now < max
    end
  end

  def missing_schema_fields
    known = Array(ctx.fields).index_by(&:id)
    page = ctx.scratch.wizard_page.to_i
    ahead = Array(ctx.schema).select { |field| field.required && field.condition.blank? }.map(&:id).select do |id|
      field = known[id]
      field.nil? || (field.target.nil? && field.page.to_i > page)
    end
    ahead.first(1).map { |id| "schema field missing: #{id}" }
  end

  def frame_outline
    frame_path = ctx.form_root&.frame_path || []
    Array(@snapshot.frames.find { |frame| frame['frame_path'] == frame_path }&.fetch('outline', nil))
  end
end
