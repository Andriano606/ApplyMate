# frozen_string_literal: true

# Learned path through one employer's application form: how to reach it
# (navigation), what each field means (field_map: fingerprint → role) and how to
# submit it. GLOBAL, not per-user — the field→role mapping is the same for
# everyone; values come from each user's own answer bank. A matching recipe
# replays with zero navigation/mapping AI calls; three consecutive failures
# delete it (the site changed).
class FormRecipe < ApplicationRecord
  MAX_FAILURES = 3

  validates :host, presence: true
  validates :form_fingerprint, presence: true, uniqueness: { scope: :host }

  def self.form_fingerprint_for(fields)
    fingerprints = Array(fields).map { |f| f.to_h.stringify_keys['fingerprint'] }.compact.sort
    Digest::SHA1.hexdigest(fingerprints.join('|'))
  end

  def self.normalize_host(url)
    URI.parse(url.to_s).host.to_s.downcase.delete_prefix('www.').presence
  rescue URI::InvalidURIError
    nil
  end

  def self.best_for(host)
    where(host:).order(success_count: :desc, last_success_at: :desc).first
  end

  def record_success!
    update!(success_count: success_count + 1, fail_count: 0, last_success_at: Time.current)
  end

  def record_failure!
    if fail_count + 1 >= MAX_FAILURES
      destroy!
    else
      update!(fail_count: fail_count + 1)
    end
  end

  def role_for(fingerprint)
    entry = field_map.find { |f| f['fingerprint'] == fingerprint }
    entry && entry['role']
  end
end
