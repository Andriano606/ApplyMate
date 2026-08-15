# frozen_string_literal: true

# Contract for ATS adapters — deterministic replacements for the browser path
# on known applicant tracking systems. An adapter may fail at any moment (URL
# shape changed, API version bumped): it must raise AdapterError, never return
# garbage — FetchFields falls back to the browser path on that error, so the
# adapter is an optimization and the generic flow is the guarantee.
class Apply::ExternalAts::Base
  class AdapterError < StandardError; end

  # ATS keys (from Apply::AtsDetector) that have a working adapter. Detected
  # systems without an entry fall back to the browser path. Class names are
  # strings to keep autoloading lazy (subclasses inherit this class).
  REGISTRY = {
    'greenhouse' => 'Apply::ExternalAts::Greenhouse',
    'lever'      => 'Apply::ExternalAts::Lever',
    'workable'   => 'Apply::ExternalAts::Workable',
    'recruitee'  => 'Apply::ExternalAts::Recruitee'
  }.freeze

  def self.for(ats)
    REGISTRY[ats.to_s]&.constantize&.new
  end

  # Returns an array of IR field hashes (same shape as Browser#snapshot_fields /
  # FormExtractor) with 'role' pre-filled — ATS APIs know field semantics, so no
  # AI mapping is needed. Raises AdapterError when the ATS answer is unusable.
  def fetch_fields(apply:)
    raise NotImplementedError
  end

  # Submits filled_inputs (+ CV via handler.build_payload). Raises AdapterError
  # on rejection. 2xx and redirect-after-post count as success.
  def submit(apply:, handler:)
    raise NotImplementedError
  end

  private

  def http
    @http ||= ApplyMate::Client::AsyncHttp.new(request_timeout: 30)
  end

  def get_json(url)
    response = http.get(url, follow_redirects: true)
    raise AdapterError, "no response from #{url}" if response.nil?
    raise AdapterError, "HTTP #{response.status} from #{url}" unless (200..299).cover?(response.status)

    JSON.parse(response.body)
  rescue JSON::ParserError => e
    raise AdapterError, "invalid JSON from #{url}: #{e.message}"
  end

  def post_multipart!(url, payload:, headers: {})
    response = http.post_multipart(url, payload:, headers:)
    raise AdapterError, "no response from #{url}" if response.nil?

    status = response.status
    return response if (200..299).cover?(status) || [ 301, 302, 303 ].include?(status)

    raise AdapterError, "HTTP #{status} from #{url}: #{response.body.to_s[0..300]}"
  end

  # Builds one IR entry; adapters know the semantics, so role comes pre-filled
  # and fingerprint is computed the same way as for browser-sourced fields.
  def ir_field(name:, role:, tag: 'input', type: 'text', label: '', required: false, options: nil, value: '', position: 0)
    entry = {
      'name' => name, 'selector' => "[name=\"#{name}\"]", 'form_index' => position,
      'position' => position, 'tag' => tag, 'type' => type,
      'accessible_name' => label, 'label' => label, 'placeholder' => '',
      'required' => required, 'autocomplete' => '', 'fieldset' => '',
      'role' => role, 'value' => value
    }
    entry['options'] = options if options.present?
    entry.merge('fingerprint' => Apply::FieldFingerprint.call(entry))
  end
end
