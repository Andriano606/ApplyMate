# frozen_string_literal: true

# The snapshot elements that belong to the application form: in the form root's frame (ReachForm's ctx.form_root,
# compared by frame path), inside the form root selector, and outside every platform.excluded_regions selector (the
# Ashby autofill-from-resume pane). The ONE "is this element part of the form" rule, for BuildFieldInventory and
# ClassifyAdvance (which button advances the form: FillFields' wizard loop, Stage::Submit).
#
# Also the ONE reader of the form root's text (FormElements.root_document / .text_of / .visible_text): the frame's
# HTML parsed with Nokogiri, text nodes outside script / style / noscript / template and outside elements the markup
# itself hides (the `hidden` attribute, an inline `display:none`; CSS-class hiding is invisible to a parse), squished.
# CollectSubmitEvidence (what the page says after the submit: a pre-rendered, hidden "Thank you" is not a success) and
# ClassifyAdvance (a "Step 1 of 2" indicator: a hidden step's indicator is not the current one) read it.
#
# The snapshot must be taken with `regions: FormElements.regions(ctx)` (probe/snapshot.js reports, per element, the
# region selectors it or its field root sits inside); FormElements.snapshot(ctx) does that. No form root ->
# Halt(:not_a_form). model = [element hash] in DOM order.
class Apply::Operation::Engine::FormElements < ApplyMate::Operation::Base
  # Text nodes a reader sees: one space between nodes (block elements must not glue words), no script/style bodies,
  # nothing under an element hidden by its own markup.
  VISIBLE_TEXT = './/text()[not(ancestor::script or ancestor::style or ancestor::noscript or ancestor::template or ' \
                 "ancestor::*[@hidden] or ancestor::*[contains(translate(@style, ' ', ''), 'display:none')])]"

  class << self
    # The form root and the excluded regions: what snapshot.js must report per element.
    def regions(ctx)
      [ root_selector(ctx), *ctx.platform&.excluded_regions ].compact.uniq
    end

    # One snapshot of every frame with the registry's DOM markers (gates, redetection) and the form regions.
    def snapshot(ctx)
      ctx.session.snapshot_all(markers: Apply::Platform::Registry.dom_markers, regions: regions(ctx))
    end

    # ReachForm builds the form root as Target.css(selector, frame_path:).
    def root_selector(ctx)
      ctx.form_root&.strategies&.first&.fetch('css', nil)
    end

    # [document, root]: the form root's frame parsed (Nokogiri) and the root element in it (nil when it is gone or
    # there is no root selector). A frame that is gone parses as an empty document.
    def root_document(ctx)
      document = Nokogiri::HTML(ctx.session.html(frame_path: ctx.form_root&.frame_path || []).to_s)
      selector = root_selector(ctx)
      [ document, selector.present? ? document.at_css(selector) : nil ]
    rescue ApplyMate::Client::Browser::TargetNotFound
      [ Nokogiri::HTML(''), nil ]
    end

    # The squished text of `node` (VISIBLE_TEXT); '' for nil.
    def text_of(node)
      return '' if node.nil?

      node.xpath(VISIBLE_TEXT).map(&:text).join(' ').squish
    end

    # The text of the form root now ('' when it is gone).
    def visible_text(ctx)
      text_of(root_document(ctx).last)
    end
  end

  def perform!(ctx:, snapshot:, **)
    skip_authorize
    root = ctx.form_root
    raise Apply::Operation::Engine::Halt.new(:not_a_form, detail: 'no form root') if root.nil?

    selector = self.class.root_selector(ctx)
    excluded = Array(ctx.platform&.excluded_regions)
    self.model = snapshot.elements.select do |element|
      regions = Array(element['regions'])
      element['target'].frame_path == root.frame_path && regions.include?(selector) && !regions.intersect?(excluded)
    end
  end
end
