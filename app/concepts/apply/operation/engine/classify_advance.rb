# frozen_string_literal: true

# Which button moves the form on, and is it the irreversible one (design §7.4, `Engine::SubmitLocator.classify`)? The
# ONE submit / next locator: Stage::FillFields (wizard loop) and Stage::Submit (the button behind the claim).
#
# Candidates: visible, enabled elements of the form (Engine::FormElements) that are submit_like (probe/snapshot.js), plus
# - only when the page shows evidence of a further page - buttons named by NEXT_LEXICON (a wizard's Next is often a
# type=button, which the probe never calls submit_like). With none of those, the form's buttons named by FINAL_LEXICON
# (a dialog's type=button "Відгукнутися" in a footer outside its <form>): inside the form root an apply / respond verb
# is the final button, outside it the same word is the page's launcher, so the snapshot's submit_like never carries it.
# With none in the form root either: the same rule over the root's nearest dialog / modal container (probe/anchor.js),
# where a modal keeps its final button in a footer outside the <form> (#dialog_finals).
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
  # The snapshot's submit lexicon (the one source, SnapshotAll::SUBMIT_TEXT) plus its apply / respond verbs
  # (SnapshotAll::APPLY_TEXT): buttons already inside the form, where "Apply" / "Відгукнутися" / "Откликнуться" is a final button.
  FINAL_LEXICON = Regexp.union(ApplyMate::Client::Browser::Operation::SnapshotAll::SUBMIT_TEXT,
                               ApplyMate::Client::Browser::Operation::SnapshotAll::APPLY_TEXT)
  STEP_INDICATOR = %r{\b(?:step|крок|шаг|page|сторінка)\s*(\d+)\s*(?:of|з|из|/|від)\s*(\d+)}i
  PROGRESSBAR = %r{\Aprogressbar (\d+(?:\.\d+)?)/(\d+(?:\.\d+)?)\z}
  BUTTON_INPUT_TYPES = %w[submit button image].freeze
  SCOPED_TAGS = %w[button a].freeze

  def perform!(ctx:, snapshot: nil, **)
    skip_authorize
    @ctx = ctx
    @snapshot = snapshot || Apply::Operation::Engine::FormElements.snapshot(ctx)
    @buttons = Apply::Operation::Engine::FormElements.call(ctx:, snapshot: @snapshot).model.select do |element|
      element['visible'] && !element['disabled']
    end
    candidates = @buttons.select { |element| element['submit_like'] || (next_button?(element) && more_pages?) }
    candidates = @buttons.select { |element| final_button?(element) } if candidates.empty?
    candidates = dialog_finals if candidates.empty?
    self.model = candidates.empty? ? nil : advance(pick(candidates))
  end

  private

  attr_reader :ctx

  def advance(button)
    name = button['name'].to_s
    kind = next_name?(name) && more_pages? ? :next : :final
    ctx.trace(:advance, kind: kind.to_s, name:, evidence:)
    Advance.new(kind:, target: scoped_target(button), name:)
  end

  # The button's target with `{ css: "<root> <tag>", has_text: name }` first: the snapshot's own strategies are the
  # page-wide { role, name } (ambiguous with a same-named page launcher and a role=button host such as CleverStaff's
  # <button-component role=button> around the native <button>) and an absolute nth-of-type path that breaks when a
  # modal is inserted at another body index. The native tag under the dialog container dialog_finals found (anchor.js
  # `container`, e.g. div[role=dialog]) is unique where the others are not; Locate falls through to the snapshot's
  # strategies when it is not. A button inside the form root keeps the snapshot's target (the form's own scope already
  # tells it apart). Only for <button> / <a> with a name (has_text reads text, not an input's value) and a
  # single-selector container.
  def scoped_target(button)
    target = button['target']
    root = @scope_css
    return target if root.blank? || root.include?(',') || SCOPED_TAGS.exclude?(button['tag']) || button['name'].blank?

    target.with(strategies: [ { 'css' => "#{root} #{button['tag']}", 'has_text' => button['name'] }, *target.strategies ])
  end

  def pick(candidates)
    return candidates.first if candidates.one?

    nexts = candidates.select { |element| next_name?(element['name']) }
    return nexts.first if nexts.one? && more_pages?

    finals = candidates.select { |element| element['name'].to_s.match?(FINAL_LEXICON) }
    return finals.first if finals.one?

    raise Apply::Operation::Engine::Halt.new(:target_not_found, detail: "submit buttons in the form: #{candidates.size}")
  end

  # The final button of a dialog whose footer sits outside its <form> (an Angular uib-modal: `.modal-footer` with a
  # type=button "Відгукнутися" next to `.modal-body > form`): the form root's nearest dialog / modal container
  # (probe/anchor.js `container`), read with one more snapshot only on this path, and its submit_like or FINAL_LEXICON
  # buttons there. [] when the root is in no dialog or is gone.
  def dialog_finals
    container = ctx.session.probe(:anchor, ctx.form_root).to_h['container']
    return [] if container.blank?

    @scope_css = container

    excluded = Array(ctx.platform&.excluded_regions)
    snapshot = ctx.session.snapshot_all(markers: Apply::Platform::Registry.dom_markers, regions: [ container, *excluded ])
    snapshot.elements.select do |element|
      regions = Array(element['regions'])
      element['target'].frame_path == ctx.form_root.frame_path && regions.include?(container) &&
        !regions.intersect?(excluded) && element['visible'] && !element['disabled'] &&
        (element['submit_like'] || final_button?(element))
    end
  rescue ApplyMate::Client::Browser::TargetNotFound
    []
  end

  def next_name?(name)
    name.to_s.match?(NEXT_LEXICON)
  end

  # A button (not an answer button of an option group) named like a Next.
  def next_button?(element)
    button?(element) && next_name?(element['name'])
  end

  # A form button (not an answer button) named like the final one.
  def final_button?(element)
    button?(element) && element['name'].to_s.match?(FINAL_LEXICON)
  end

  def button?(element)
    button = element['tag'] == 'button' || element['role'] == 'button' ||
             (element['tag'] == 'input' && BUTTON_INPUT_TYPES.include?(element['type']))
    button && element['group'].nil?
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
