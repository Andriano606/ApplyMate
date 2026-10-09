# frozen_string_literal: true

# Session#snapshot_all: runs probe/snapshot.js and probe/detect.js (one evaluate per frame, Driver#evaluate_all_frames,
# at most Driver::Playwright::MAX_FRAMES frames) and turns the per-frame results into a Snapshot whose elements carry
# refs and Targets that Operation::Locate resolves. `markers` are counted by detect.js; `regions` (CSS selectors) are
# reported per element by snapshot.js ('regions' => the ones the element or its field root sits inside).
#
# Frame paths: a child frame's hop is { 'selector' => 'iframe#<id>' } when the <iframe> element has a CSS-safe id
# (read from the parent side, so it works across origins), else { 'url_contains' => <frame url> }; nested frames
# chain their parents' hops. A frame that cannot be evaluated (detached, navigating) is listed with
# 'readable' => false and contributes no elements.
class ApplyMate::Client::Browser::Operation::SnapshotAll < ApplyMate::Operation::Base
  PROBES = ApplyMate::Client::Browser::Driver::Playwright::PROBES
  FRAME_JS = <<~JS.freeze
    (arg) => {
      const root = document.documentElement;
      return {
        snapshot: (#{PROBES.fetch(:snapshot)})(root, arg),
        detect: (#{PROBES.fetch(:detect)})(root, arg),
      };
    }
  JS
  CSS_ID = /\A[A-Za-z_][\w-]*\z/
  STYLED_TYPES = %w[radio checkbox file].freeze
  # Element state that is part of the digest besides the fingerprint: a click that reveals a hidden section, opens an
  # accordion or selects a tab changes the page without adding elements (the Navigator's "did anything change?").
  DIGEST_STATE = %w[visible expanded selected pressed checked disabled].freeze

  # The ONE page-state digest: SHA1 over each element's fingerprint and DIGEST_STATE values, in order. Values
  # (`filled`) are left out, so typing never changes it.
  def self.digest_of(elements)
    Digest::SHA1.hexdigest(elements.map { |element| [ element['fingerprint'], *element.values_at(*DIGEST_STATE) ].join('|') }.join("\n"))
  end

  def perform!(driver:, markers: [], regions: [], **)
    skip_authorize
    raw = driver.evaluate_all_frames(FRAME_JS, { 'markers' => markers, 'regions' => regions })
    paths = frame_paths(raw)
    elements = raw.flat_map { |frame| elements_of(frame, paths.fetch(frame[:index])) }
    self.model = ApplyMate::Client::Browser::Snapshot.new(
      frames: raw.map { |frame| frame_entry(frame, paths.fetch(frame[:index])) },
      elements:,
      evidence: evidence(raw, markers),
      digest: self.class.digest_of(elements)
    )
  end

  private

  # Driver#evaluate_all_frames lists the main frame first and frames in attach order, so a parent's path exists
  # before its children's. A child whose parent path is unknown (parent beyond MAX_FRAMES) gets one flat
  # url_contains hop (Locate searches every frame for it), never the main frame's path.
  def frame_paths(raw)
    raw.each_with_object({}) do |frame, paths|
      parent_path = paths[frame[:parent_index]]
      paths[frame[:index]] =
        if frame[:index].zero? then []
        elsif parent_path then parent_path + [ hop(frame) ]
        else [ { 'url_contains' => frame[:url] } ]
        end
    end
  end

  def hop(frame)
    id = frame[:element_id]
    return { 'selector' => "iframe##{id}" } if id.present? && CSS_ID.match?(id)

    { 'url_contains' => frame[:url] }
  end

  def frame_entry(frame, path)
    snapshot = frame.dig(:value, 'snapshot') || {}
    parent = frame[:parent_index]
    {
      'ref' => "f#{frame[:index]}", 'index' => frame[:index], 'url' => frame[:url],
      'title' => snapshot.dig('frame', 'title'), 'parent' => parent && "f#{parent}", 'frame_path' => path,
      'outline' => snapshot.fetch('outline', []), 'alerts' => snapshot.fetch('alerts', []),
      'captcha' => snapshot.fetch('captcha', []), 'password_fields' => snapshot.fetch('password_fields', 0),
      'truncated' => snapshot.fetch('truncated', false), 'readable' => snapshot.present?
    }
  end

  def elements_of(frame, path)
    index = frame[:index]
    Array(frame.dig(:value, 'snapshot', 'elements')).map do |element|
      element.merge('ref' => "f#{index}:e#{element['index']}", 'frame' => "f#{index}",
                    'fingerprint' => fingerprint(element, index), 'target' => target(element, path))
    end
  end

  def fingerprint(element, frame_index)
    "#{element['role'] || element['tag']}|#{element['name'].to_s.downcase}|f#{frame_index}"
  end

  # The field root is the visibility reference only for controls a person never sees themselves (styled radios and
  # checkboxes, clipped file inputs, transparent combobox inputs); a plain input must be visible itself.
  def target(element, path)
    styled = STYLED_TYPES.include?(element['type']) || (element['visible'] && !element['self_visible'])
    ApplyMate::Client::Browser::Target.new(frame_path: path, strategies: element.fetch('strategies'),
                                           root: styled ? element['root_strategies'] : nil,
                                           readonly: element['readonly'] || false)
  end

  def evidence(raw, markers)
    detected = raw.filter_map { |frame| frame.dig(:value, 'detect') }
    {
      frame_urls: raw.pluck(:url),
      script_srcs: detected.flat_map { |detect| detect['script_srcs'] }.uniq,
      iframe_srcs: detected.flat_map { |detect| detect['iframe_srcs'] }.uniq,
      dom_markers: markers.index_with { |marker| detected.sum { |detect| detect.dig('dom_markers', marker).to_i } }
    }
  end
end
