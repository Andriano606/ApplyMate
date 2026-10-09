# frozen_string_literal: true

# The list of platform adapters (design §4.1). PLATFORMS are detected from evidence (Engine::Detect);
# BOARD_PLATFORMS (phase 4: DOU / Djinni in-board forms) are pinned by ResolveTarget and never detected.
# spec/concepts/apply/platform/registry_completeness_spec.rb fails when an adapter in app/concepts/apply/platform/
# is missing here or listed twice.
class Apply::Platform::Registry
  PLATFORMS = %w[Apply::Platform::Ashby].freeze
  BOARD_PLATFORMS = [].freeze
  THRESHOLD = 0.8
  FINGERPRINT_VERSION = 1 # bump when detection semantics change without a signal change

  class << self
    def platforms
      @platforms ||= PLATFORMS.map(&:constantize).freeze
    end

    def board_platforms
      @board_platforms ||= BOARD_PLATFORMS.map(&:constantize).freeze
    end

    # Selectors of every :dom signal: what probe/detect.js counts in each frame (Session#snapshot_all(markers:)).
    def dom_markers
      @dom_markers ||= platforms.flat_map { |p| p.signals.select { |s| s.kind == :dom }.map(&:pattern) }.uniq.freeze
    end

    # Host patterns of every :host signal: hosts the engine knows (the origin check of a form outside the entry site).
    def known_hosts
      @known_hosts ||= platforms.flat_map { |p| p.signals.select { |s| s.kind == :host }.map(&:pattern) }.freeze
    end

    def known_host?(host)
      host.present? && known_hosts.any? { |pattern| pattern.match?(host.downcase) }
    end

    # Part of DetectPlatform's input digest: a new adapter or a changed signal invalidates earlier detections.
    def fingerprint
      @fingerprint ||= fingerprint_of(platforms)
    end

    def fingerprint_of(platform_classes)
      Digest::SHA256.hexdigest(
        [ FINGERPRINT_VERSION, platform_classes.map { |p| [ p.key, p.priority, p.signals.map(&:to_h) ] } ].to_json
      )
    end

    def find!(key)
      return Apply::Platform::Generic if key == Apply::Platform::Generic.key

      (platforms + board_platforms).find { |p| p.key == key } || raise(ArgumentError, "Unknown platform key #{key.inspect}")
    end
  end
end
