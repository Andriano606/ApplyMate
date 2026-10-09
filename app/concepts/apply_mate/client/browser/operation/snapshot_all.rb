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
#
# Frame visibility: a frame renders only when every <iframe> on its chain does (Driver's host_visible, ANDed down the
# parents). Elements of a frame that does not render (Lever's hCaptcha enclave: a full-page iframe with
# visibility:hidden, whose "Verify Answers" div reports itself visible) are reported 'visible' / 'self_visible' /
# 'in_viewport' false and its 'password_fields' 0, so the Navigator is never offered controls nobody can see; the
# frame entry carries 'visible'.
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
  # The ONE send-the-application lexicon: snapshot.js marks a buttonish element near fields `submit_like` when its
  # name / class matches it (the Navigator's no-submit guard, Engine::ExecuteAction), and Engine::ClassifyAdvance's
  # FINAL_LEXICON is built from it. Portable regex source (Ruby and JS read it alike). A bare "apply" is NOT in it:
  # "Apply now" is how a vacancy page leads to its form. "send" is a whole word, and nothing that sends a CODE / OTP
  # ("Resend code", "Send verification code", "Надіслати код") counts: an email-verification button beside the fields
  # is neither the final button nor a send the guard must refuse.
  SUBMIT_TEXT = /^(?!.*(\b(code|otp)\b|(^|\s)код)).*(submit|\bsend\b|надіслати|відправити|подати|отправить)/i
  # The apply / respond verbs: a final button ("Apply", "Відгукнутися", "Откликнуться") only where it has something
  # to send, so snapshot.js marks them submit_like only on a non-navigating buttonish element whose dialog / form scope
  # holds another fillable control (a CleverStaff uib-modal's "Відгукнутися"); outside any scope "Apply now" is the
  # launcher the Navigator must click. Engine::ClassifyAdvance::FINAL_LEXICON = SUBMIT_TEXT | APPLY_TEXT.
  APPLY_TEXT = /apply|відгукн|откликн/i
  STYLED_TYPES = %w[radio checkbox file].freeze
  # What an element of a frame whose iframe chain does not render reports, whatever its own document computed.
  HIDDEN_FRAME_STATE = { 'visible' => false, 'self_visible' => false, 'in_viewport' => false }.freeze
  # Element state that is part of the digest besides the fingerprint: a click that reveals a hidden section, opens an
  # accordion or selects a tab changes the page without adding elements (the Navigator's "did anything change?").
  DIGEST_STATE = %w[visible expanded selected pressed checked disabled].freeze

  # The ONE page-state digest: SHA1 over each element's fingerprint and DIGEST_STATE values, in order. Values
  # (`filled`) are left out, so typing never changes it.
  def self.digest_of(elements)
    Digest::SHA1.hexdigest(elements.map { |element| [ element['fingerprint'], *element.values_at(*DIGEST_STATE) ].join('|') }.join("\n"))
  end

  # snapshot.js's argument; every caller of the probe (this operation, a widget's scoped Session#probe(:snapshot))
  # passes it, so the submit lexicon has one source.
  def self.probe_arg(markers: [], regions: [])
    { 'markers' => markers, 'regions' => regions, 'submitText' => SUBMIT_TEXT.source, 'applyText' => APPLY_TEXT.source }
  end

  def perform!(driver:, markers: [], regions: [], **)
    skip_authorize
    raw = driver.evaluate_all_frames(FRAME_JS, self.class.probe_arg(markers:, regions:))
    paths = frame_paths(raw)
    rendered = rendered_frames(raw)
    elements = raw.flat_map { |frame| elements_of(frame, paths.fetch(frame[:index]), rendered.fetch(frame[:index])) }
    self.model = ApplyMate::Client::Browser::Snapshot.new(
      frames: raw.map { |frame| frame_entry(frame, paths.fetch(frame[:index]), rendered.fetch(frame[:index])) },
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

  # { frame index => true when its iframe chain renders }. Parents precede children (see #frame_paths); a frame whose
  # parent is unknown (beyond MAX_FRAMES) is judged on its own host; a host not reported (canned results) is visible.
  def rendered_frames(raw)
    raw.each_with_object({}) do |frame, rendered|
      rendered[frame[:index]] = frame[:host_visible] != false && rendered.fetch(frame[:parent_index], true)
    end
  end

  def frame_entry(frame, path, rendered)
    snapshot = frame.dig(:value, 'snapshot') || {}
    parent = frame[:parent_index]
    {
      'ref' => "f#{frame[:index]}", 'index' => frame[:index], 'url' => frame[:url],
      'title' => snapshot.dig('frame', 'title'), 'parent' => parent && "f#{parent}", 'frame_path' => path,
      'visible' => rendered, 'outline' => snapshot.fetch('outline', []), 'alerts' => snapshot.fetch('alerts', []),
      'captcha' => snapshot.fetch('captcha', []), 'password_fields' => rendered ? snapshot.fetch('password_fields', 0) : 0,
      'truncated' => snapshot.fetch('truncated', false), 'readable' => snapshot.present?
    }
  end

  def elements_of(frame, path, rendered)
    index = frame[:index]
    seen = Hash.new(0)
    Array(frame.dig(:value, 'snapshot', 'elements')).map do |element|
      element = element.merge(HIDDEN_FRAME_STATE) unless rendered
      element.merge('ref' => "f#{index}:e#{element['index']}", 'frame' => "f#{index}",
                    'fingerprint' => fingerprint(element, index, seen), 'target' => target(element, path))
    end
  end

  # "role|name|f<frame>", then "|<scope>" (snapshot.js: 'dialog' / 'form', with "#id" for a stable container id, else "@n") when
  # the element acts inside a dialog or form, then "#<n>" for the n-th (n >= 1) repeat of that same key. The scope is
  # the structural discriminator: a modal's "Відгукнутися" never inherits the page launcher's identity (and its
  # FORBIDDEN entry) wherever the modal is inserted, and the page's own repeats keep their numbers. Two "Apply"
  # launchers are two things (the Navigator's FORBIDDEN list must not bar the second for the first's sake).
  def fingerprint(element, frame_index, seen)
    base = "#{element['role'] || element['tag']}|#{element['name'].to_s.downcase}|f#{frame_index}"
    base = "#{base}|#{element['scope']}" if element['scope'].present?
    occurrence = seen[base]
    seen[base] += 1
    occurrence.zero? ? base : "#{base}##{occurrence}"
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
