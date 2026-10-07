# Resolves a Target to exactly one Playwright locator (Target::Locator rules, design §9.1):
# 1. frame_path, hop by hop: { 'selector' } chains frame_locator; { 'url_contains' } / { 'name' } pick from
#    driver.frames (a flat list, so these hops search the whole page). An unknown frame -> TargetNotFound.
# 2. strategies in order; a strategy is accepted only when it matches exactly ONE element in the DOM (0 or >1 ->
#    next), hidden or not. visibility :required then also needs that one element to be visible, or, when
#    target.root is set (styled controls), the root to match exactly one element that is visible and the element
#    merely be attached. :attached: in the DOM only. The uniqueness count never filters by visibility, so a target
#    resolves to the same element in both modes (a hidden duplicate makes the strategy a miss in both).
# 3. nothing accepted -> TargetNotFound (#ambiguous? when some strategy matched several elements). model = the
#    locator.
# Counting does not wait: callers wait for the page first (Session#ready?, #settle). An invalid selector counts
# as a miss; a lost connection raises Crashed (Driver#count).
class ApplyMate::Client::Browser::Operation::Locate < ApplyMate::Operation::Base
  VISIBILITIES = %i[required attached].freeze
  ATTR_NAME = /\A[A-Za-z_:][-\w:.]*\z/

  def perform!(driver:, target:, visibility:, **)
    skip_authorize
    raise ArgumentError, "unknown visibility #{visibility.inspect}" unless VISIBILITIES.include?(visibility)

    scope = frame_scope(driver, target)
    visible = element_must_be_visible?(driver, scope, target, visibility)
    locator, ambiguous = unique(driver, scope, target.strategies, visible:)
    self.model = locator || raise(not_found(target, ambiguous:))
  end

  private

  def element_must_be_visible?(driver, scope, target, visibility)
    return false if visibility == :attached
    return true if target.root.blank?
    raise not_found(target, 'field root is not visible') unless root_visible?(driver, scope, target.root)

    false
  end

  def frame_scope(driver, target)
    target.frame_path.reduce(driver.main_frame) do |scope, hop|
      next scope.frame_locator(hop['selector']) if hop['selector'].present?

      frame = driver.frames.find { |candidate| frame_matches?(candidate, hop) }
      frame || raise(not_found(target, "no frame matches #{hop.to_json.truncate(200)}"))
    end
  end

  def frame_matches?(frame, hop)
    return frame.url.include?(hop['url_contains']) if hop['url_contains'].present?

    hop['name'].present? && frame.name == hop['name']
  end

  def root_visible?(driver, scope, root_strategies)
    unique(driver, scope, root_strategies, visible: true).first.present?
  end

  # [locator or nil, whether any strategy matched several elements]
  def unique(driver, scope, strategies, visible:)
    ambiguous = false
    strategies.each do |strategy|
      locator = build(scope, strategy)
      next unless locator

      matches = count(driver, locator)
      ambiguous ||= matches > 1
      next unless matches == 1
      return [ locator, false ] if !visible || count(driver, locator.filter(visible: true)) == 1
    end
    [ nil, ambiguous ]
  end

  def build(scope, strategy)
    if strategy['css'].present?
      css(scope, strategy)
    elsif strategy['role'].present?
      scope.get_by_role(strategy['role'], name: strategy['name'].presence)
    elsif strategy['label'].present?
      scope.get_by_label(strategy['label'])
    elsif strategy['attr'].is_a?(Hash) && strategy['attr'].present?
      attribute_selector(strategy['attr'])&.then { |selector| scope.locator(selector) }
    end
  end

  def css(scope, strategy)
    locator = scope.locator(strategy['css'])
    locator = locator.filter(hasText: strategy['has_text']) if strategy['has_text'].present?
    strategy['nth'].nil? ? locator : locator.nth(strategy['nth'].to_i)
  end

  # { 'name' => 'email', 'data-qa' => 'x' } -> [name="email"][data-qa="x"]; an unsafe attribute name skips the
  # strategy instead of building a selector from it.
  def attribute_selector(attrs)
    return unless attrs.keys.all? { |name| ATTR_NAME.match?(name.to_s) }

    attrs.map { |name, value| %([#{name}="#{value.to_s.gsub(/["\\]/) { |char| "\\#{char}" }}"]) }.join
  end

  def count(driver, locator)
    driver.count(locator)
  rescue ::Playwright::Error
    0 # invalid selector syntax: a miss, not a crash
  end

  def not_found(target, reason = nil, ambiguous: false)
    message = reason && "#{reason}: #{target.strategies.to_json.truncate(300)}"
    ApplyMate::Client::Browser::TargetNotFound.new(target, message, ambiguous:)
  end
end
