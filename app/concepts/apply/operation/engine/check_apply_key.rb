# frozen_string_literal: true

# Cross-board duplicate check (design §11.2). The apply key is the platform's posting identity
# (`platform.apply_key`, e.g. "ashby:preply:<jid>"), else the normalized form URL ("host/path", lowercase host
# without www., no query / fragment / trailing slash), else nil (no form URL known yet: nothing to compare; the
# entry URL is never used, a job-board redirector such as dou.ua/goto/vacancy/ would make every vacancy one key).
#
# Halt(:already_applied, detail: <previous apply hashid>) -> needs_review when another apply of the same user with
# the same key is completed / submit_unverified or holds a submit claim, unless the user confirmed the duplicate
# (applies.duplicate_confirmed_at). Rides index_applies_on_user_apply_key (user_id, apply_key) WHERE apply_key IS
# NOT NULL. model = the key (String or nil).
class Apply::Operation::Engine::CheckApplyKey < ApplyMate::Operation::Base
  SUBMITTED_STATES = %w[completed submit_unverified].freeze

  # The earlier apply of the same user and key that was (maybe) sent, or nil. Also used by Answer::ReviewReasons.
  def self.previous_apply(apply, key)
    Apply.where(user_id: apply.user_id, apply_key: key).where.not(id: apply.id)
         .where('state IN (?) OR submit_claimed_at IS NOT NULL', Apply.states.values_at(*SUBMITTED_STATES))
         .order(:id).last
  end

  # "host/path" of a URL (lowercase host without www., no query / fragment / trailing slash), or nil: the one
  # "same page" normalization (the default apply key; ReachForm's "already on the canonical form URL").
  def self.normalized_url(url)
    return if url.blank?

    uri = URI.parse(url)
    return if uri.host.blank?

    "#{uri.host.downcase.delete_prefix('www.')}#{uri.path.to_s.chomp('/')}"
  rescue URI::InvalidURIError
    nil
  end

  def perform!(ctx:, **)
    skip_authorize
    self.model = ctx.platform&.apply_key || self.class.normalized_url(ctx.form_url)
    return if model.nil? || ctx.apply.duplicate_confirmed_at.present?

    previous = self.class.previous_apply(ctx.apply, model)
    raise Apply::Operation::Engine::Halt.new(:already_applied, detail: previous.hashid) if previous
  end
end
