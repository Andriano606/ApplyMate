# frozen_string_literal: true

class Apply < ApplicationRecord
  belongs_to :user
  belongs_to :vacancy
  belongs_to :user_profile
  belongs_to :ai_integration
  belongs_to :source_profile
  belongs_to :fill_form_prompt, class_name: 'Prompt', optional: true
  belongs_to :generate_cv_prompt, class_name: 'Prompt', optional: true

  validate :source_must_match

  has_one_attached :cv
  has_one_attached :screenshot

  jsonb_accessor :form_data,
    action:           :string, # form action URL (resolved absolute)
    http_method:      :string, # HTTP method extracted from the form element ('post', 'get')
    submit_selector:  :string, # CSS selector for the submit button
    submit_text:      :string, # visible text of the submit button, used for disambiguation
    external_url:     :string, # canonical URL of the employer's application page
    trigger_selector: :string, # CSS selector to click before the form appears (e.g. "Apply" button)
    cookies:          :string, # cookies captured at form-fetch time, forwarded on HTTP submission
    inputs:           :value   # Array<{ name, selector, form_index, tag, type, label, placeholder, value, options? }>

  jsonb_accessor :filled_form_data,
    filled_inputs: :value  # same shape as inputs, with AI-filled values

  enum :apply_type, { unknown: 0, external: 1, internal: 2 }

  enum :state, {
    queued: 0,
    running: 1,
    waiting_capacity: 2,
    needs_review: 3,
    needs_human: 4,
    completed: 5,
    failed: 6,
    unsupported: 7,
    submit_unverified: 8,
    cancelled: 9
  }

  # State lists. The partial indexes in db/migrate/20261007000001_apply_engine_state.rb use the integer values;
  # spec/models/apply_indexes_spec.rb keeps them in sync with these lists.
  ACTIVE_STATES = %w[queued running waiting_capacity needs_review needs_human].freeze
  IN_PROGRESS_STATES = %w[queued running waiting_capacity].freeze
  ATTENTION_STATES = %w[needs_review needs_human failed unsupported submit_unverified].freeze
  RESUMABLE_STATES = %w[failed unsupported needs_human].freeze
  CANCELLABLE_STATES = %w[queued needs_human failed unsupported needs_review].freeze
  WAITING_STATES = %w[needs_review needs_human].freeze # waiting on the user: ExpireWaiting reminds, then expires

  # Timing used by the engine and the recurring reaper/expiry jobs (single source for the SQL too).
  RUN_DEADLINE = 30.minutes
  STALE_AFTER = 3.minutes
  HEARTBEAT_GRACE = 5.minutes
  REAPER_GRACE = 15.minutes
  HUMAN_TIMEOUT = 7.days
  REVIEW_TIMEOUT = 72.hours
  WAIT_TIMEOUTS = { 'needs_human' => HUMAN_TIMEOUT, 'needs_review' => REVIEW_TIMEOUT }.freeze
  REMIND_AFTER = 48.hours
  # Reminder not yet shown for the current wait (every transition bumps updated_at; the reminder write does not).
  # Matches the predicate of index_applies_remind_candidates.
  REMINDER_DUE_SQL = '(reminded_at IS NULL OR reminded_at < updated_at)'

  has_many :apply_steps, dependent: :destroy

  # Applies that belong in the vacancy page CV list: a CV is attached, or the pipeline is generating one.
  # The EXISTS rides index_active_storage_attachments_uniqueness (record_type, record_id, name, blob_id).
  scope :with_cv_or_generating_cv, lambda {
    cv_attachment = ActiveStorage::Attachment.where(record_type: name, name: 'cv')
                                             .where(ActiveStorage::Attachment.arel_table[:record_id].eq(arel_table[:id]))
    running.where(stage: 'generate_cv').or(where(cv_attachment.arel.exists))
  }

  # Rides index_applies_on_user_state when combined with a user.
  scope :attention, -> { where(state: ATTENTION_STATES) }

  # A previous apply for this vacancy may already have submitted: re-applying needs explicit confirmation.
  # Rides index_applies_on_vacancy_id.
  scope :reapply_guarded, lambda { |vacancy:, user:|
    where(vacancy:, user:).where.not(state: :cancelled).where('submit_claimed_at IS NOT NULL OR submitted_at IS NOT NULL')
  }

  # Another (non-cancelled) apply of the same user + vacancy claimed or submitted: re-running `apply` would send a
  # second application, so Resume refuses it (Create asks confirm_reapply for the same case).
  # Rides index_applies_on_vacancy_id.
  scope :submitted_sibling_of, lambda { |apply|
    reapply_guarded(vacancy: apply.vacancy_id, user: apply.user_id).where.not(id: apply.id)
  }

  # The apply a vacancy card's status badge and the vacancy page's action box describe.
  # Rides index_applies_on_vacancy_id.
  def self.latest_for(vacancy:, user:)
    where(vacancy:, user:).order(:created_at).last
  end

  # Navbar counter. The key changes whenever an engine transition calls touch_user_applies_changed_at! (after the
  # change is committed). Microsecond resolution: two transitions in the same second must not share a key.
  def self.attention_count_for(user)
    Rails.cache.fetch([ :apply_attention, user.id, user.applies_changed_at&.iso8601(6) ]) do
      where(user:).attention.count
    end
  end

  def touch_user_applies_changed_at!
    user.touch(:applies_changed_at)
  end

  def in_progress?
    IN_PROGRESS_STATES.include?(state)
  end

  def needs_attention?
    ATTENTION_STATES.include?(state)
  end

  # failure is jsonb: string keys after a reload, symbol keys on a freshly assigned instance.
  def failure_info
    (failure || {}).with_indifferent_access
  end

  def failure_code
    failure_info[:code].presence
  end

  def claimed?
    submit_claimed_at.present?
  end

  # Resume needs a resumable state, no claim of its own and no sibling apply that already claimed or submitted
  # (the sibling query runs only for resumable states). Resume repeats the sibling check inside its UPDATE.
  def resumable?
    RESUMABLE_STATES.include?(state) && !claimed? && !Apply.submitted_sibling_of(self).exists?
  end

  # The wait ends (ExpireWaiting) at this time; nil outside WAITING_STATES.
  def wait_expires_at
    timeout = WAIT_TIMEOUTS[state]
    updated_at + timeout if timeout && updated_at
  end

  # ExpireWaiting sent the 48 h reminder for the current wait.
  def reminded?
    reminded_at.present? && updated_at.present? && reminded_at >= updated_at
  end

  private

  def source_must_match
    return if vacancy.blank? || source_profile.blank?

    return if source_profile.source_id == vacancy.source_id

    errors.add(:source_profile, 'must belong to the same source as the vacancy')
  end
end
