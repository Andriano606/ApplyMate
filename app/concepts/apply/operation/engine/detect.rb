# frozen_string_literal: true

# The one platform detector (design §4.1): scores every Apply::Platform::Registry.platforms class against the
# evidence and returns the best Match, or Match.generic(probable: best) below Registry::THRESHOLD.
#
# Per platform: for each signal kind the highest weight among its matching signals counts; kinds combine by
# noisy-or (1 - Π(1 - w)); captures of all matching signals merge (the stronger signal wins a clash). Where a signal
# looks:
#   host, url, query_param   only Evidence#current_urls (final URL of the redirect chain, URLs of the current
#                            frames): intermediate hops (dou.ua/goto/...) never score
#   frame_src                Evidence#iframe_srcs (its match text becomes Match#frame_path)
#   script_src               Evidence#script_srcs
#   dom                      Evidence#dom_markers (selector => count, > 0 matches)
#   host aliases             Evidence#host_aliases (learned recipes, phase 6; always empty in 3a), HOST_ALIAS_WEIGHT
# A platform whose merged captures lack a `required_captures` name is cut to THRESHOLD - 0.01 (stays `probable`
# until a rendered redetect adds them). Ties on confidence go to the higher `priority`.
class Apply::Operation::Engine::Detect < ApplyMate::Operation::Base
  HOST_ALIAS_WEIGHT = 0.5
  MAX_ENTRIES = 200 # per Evidence list: a page with thousands of scripts must not grow the evidence without bound

  # What detection looks at. Lists of URL strings; dom_markers { selector => count }; host_aliases
  # [{ 'host', 'platform', 'captures' }].
  class Evidence < Data.define(:current_urls, :hops, :script_srcs, :iframe_srcs, :dom_markers, :host_aliases)
    LISTS = %i[current_urls hops script_srcs iframe_srcs host_aliases].freeze

    def self.empty
      new(current_urls: [], hops: [], script_srcs: [], iframe_srcs: [], dom_markers: {}, host_aliases: [])
    end

    def self.build(**attrs)
      empty.with(**attrs.slice(*members)).normalized
    end

    # Rendered level: Session#snapshot_all's evidence (every frame's URL is a current URL).
    def self.from_snapshot(snapshot)
      evidence = snapshot.evidence
      build(current_urls: evidence[:frame_urls], script_srcs: evidence[:script_srcs],
            iframe_srcs: evidence[:iframe_srcs], dom_markers: evidence[:dom_markers])
    end

    def self.from_h(hash)
      build(**hash.to_h.symbolize_keys)
    end

    # Union of the lists (this evidence first), the larger count per DOM marker.
    def merge(other)
      lists = LISTS.index_with { |name| public_send(name) + other.public_send(name) }
      markers = dom_markers.merge(other.dom_markers) { |_selector, mine, theirs| [ mine, theirs ].max }
      self.class.build(**lists, dom_markers: markers)
    end

    def normalized
      lists = LISTS.index_with { |name| Array(public_send(name)).compact.uniq.first(MAX_ENTRIES) }
      markers = dom_markers.to_h.transform_keys(&:to_s).transform_values(&:to_i)
      with(**lists, dom_markers: markers)
    end

    def to_h
      super.transform_keys(&:to_s)
    end
  end

  # Result of detection. captures: { 'slug' => ..., 'jid' => ... } (string keys: it round-trips through jsonb);
  # frame_path: [{ 'url_contains' => ... }] of the frame_src match or nil; probable: the best sub-threshold Match of a
  # generic result.
  class Match < Data.define(:key, :confidence, :captures, :frame_path, :from_alias, :probable)
    GENERIC_KEY = 'generic'

    def self.generic(probable: nil)
      new(key: GENERIC_KEY, confidence: 0.0, captures: {}, frame_path: nil, from_alias: false, probable:)
    end

    def self.from_h(hash)
      attrs = hash.to_h.stringify_keys
      new(key: attrs.fetch('key'), confidence: attrs['confidence'].to_f, captures: attrs['captures'].to_h,
          frame_path: attrs['frame_path'], from_alias: attrs['from_alias'] || false,
          probable: attrs['probable'] && from_h(attrs['probable']))
    end

    def generic?
      key == GENERIC_KEY
    end

    def known?
      !generic?
    end

    def from_alias?
      from_alias
    end

    def to_h
      { 'key' => key, 'confidence' => confidence, 'captures' => captures, 'frame_path' => frame_path,
        'from_alias' => from_alias, 'probable' => probable&.to_h }
    end
  end

  # One matching signal: its weight, captures and (frame_src) frame path.
  Hit = Data.define(:kind, :weight, :captures, :frame_path, :from_alias)

  def perform!(evidence:, **)
    skip_authorize
    scored = Apply::Platform::Registry.platforms.filter_map { |platform| score(platform, evidence) }
    best = scored.max_by { |platform, match| [ match.confidence, platform.priority ] }&.last
    self.model = best && best.confidence >= Apply::Platform::Registry::THRESHOLD ? best : Match.generic(probable: best)
  end

  private

  def score(platform, evidence)
    hits = platform.signals.flat_map { |signal| hits_of(signal, evidence) } + alias_hits(platform, evidence)
    return if hits.empty?

    strongest = hits.group_by(&:kind).transform_values { |kind_hits| kind_hits.max_by(&:weight) }
    confidence = 1 - strongest.values.reduce(1.0) { |miss, hit| miss * (1 - hit.weight) }
    captures = hits.sort_by(&:weight).reduce({}) { |merged, hit| merged.merge(hit.captures) }
    confidence = [ confidence, Apply::Platform::Registry::THRESHOLD - 0.01 ].min \
      unless platform.required_captures.all? { |name| captures[name.to_s].present? }

    [ platform, Match.new(key: platform.key, confidence: confidence.round(4), captures:,
                          frame_path: hits.select(&:frame_path).max_by(&:weight)&.frame_path,
                          from_alias: hits.any?(&:from_alias), probable: nil) ]
  end

  def hits_of(signal, evidence)
    case signal.kind
    when :host then evidence.current_urls.filter_map { |url| host_hit(signal, url) }
    when :url then evidence.current_urls.filter_map { |url| pattern_hit(signal, url) }
    when :query_param then evidence.current_urls.filter_map { |url| query_hit(signal, url) }
    when :frame_src then evidence.iframe_srcs.filter_map { |src| pattern_hit(signal, src, frame: true) }
    when :script_src then evidence.script_srcs.filter_map { |src| pattern_hit(signal, src) }
    when :dom then evidence.dom_markers[signal.pattern].to_i.positive? ? [ hit(signal, {}) ] : []
    end
  end

  def host_hit(signal, url)
    host = host_of(url)
    host && signal.pattern.match?(host) ? hit(signal, {}) : nil
  end

  def pattern_hit(signal, value, frame: false)
    found = signal.pattern.match(value)
    return if found.nil?

    hit(signal, named(found, signal), frame_path: frame ? [ { 'url_contains' => found[0] } ] : nil)
  end

  def query_hit(signal, url)
    value = query_of(url)[signal.pattern]&.first
    return if value.blank?

    hit(signal, signal.captures.first ? { signal.captures.first.to_s => value } : {})
  end

  def alias_hits(platform, evidence)
    hosts = evidence.current_urls.filter_map { |url| host_of(url) }
    evidence.host_aliases.filter_map do |entry|
      next unless entry['platform'] == platform.key && hosts.include?(entry['host'])

      Hit.new(kind: :host_alias, weight: HOST_ALIAS_WEIGHT, captures: entry['captures'].to_h, frame_path: nil,
              from_alias: true)
    end
  end

  def hit(signal, captures, frame_path: nil)
    Hit.new(kind: signal.kind, weight: signal.weight, captures:, frame_path:, from_alias: false)
  end

  def named(found, signal)
    names = signal.captures.map(&:to_s)
    found.named_captures.select { |name, value| names.include?(name) && value.present? }
  end

  def host_of(url)
    URI.parse(url.to_s).host&.downcase
  rescue URI::InvalidURIError
    nil
  end

  def query_of(url)
    CGI.parse(URI.parse(url.to_s).query.to_s)
  rescue URI::InvalidURIError
    {}
  end
end
