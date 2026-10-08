# frozen_string_literal: true

# The answers of a needs_review apply, editable before they are sent (design §8.2, §11.4): why the run stopped, one row
# per answered or required field with its source chip, the consent texts and the duplicate confirmation. Posts
# answers[<field_id>] to Apply::Operation::ApproveReview. Rendered inside StatusUpdate broadcasts, hence the LAZY user.
class Apply::Component::ReviewForm < ApplyMate::Component::Base
  LAZY = :lazy

  INPUT_CLASSES = 'block w-full rounded-lg border border-gray-300 bg-white px-3 py-2 text-sm text-gray-900 ' \
                  'focus:border-indigo-500 focus:ring-indigo-500 dark:border-gray-600 dark:bg-gray-700 dark:text-gray-100'
  CHIP_CLASSES = 'inline-flex items-center rounded-full bg-gray-100 px-2 py-0.5 text-xs text-gray-600 ' \
                 'dark:bg-gray-700 dark:text-gray-300'
  SECTION_CLASSES = 'rounded-lg border border-indigo-200 bg-white p-3 dark:border-indigo-900/50 dark:bg-gray-800 sm:p-4'
  ALERT_CLASSES = 'rounded-lg border border-amber-300 bg-amber-50 p-2 text-amber-900 ' \
                  'dark:border-amber-800 dark:bg-amber-900/20 dark:text-amber-200'
  DUPLICATE_CLASSES = 'flex items-start gap-2 rounded-lg border border-amber-300 bg-amber-50 p-3 text-sm ' \
                      'text-amber-900 dark:border-amber-800 dark:bg-amber-900/20 dark:text-amber-200'
  TEXT_KINDS = %w[text email tel url number date range].freeze
  CONSENT_SEMANTICS = %w[consent_required marketing_opt_in].freeze
  FORM_ID_PREFIX = 'review_form_'

  def initialize(apply:, user: LAZY)
    @apply       = apply
    @user_preset = user
  end

  def before_render
    @user = @user_preset == LAZY ? current_user : @user_preset
  end

  def render?
    @apply.needs_review?
  end

  private

  def form_id
    "#{FORM_ID_PREFIX}#{@apply.hashid}"
  end

  # The review gate (code 'review') lists its reasons in detail; CheckApplyKey's already_applied carries the earlier
  # apply's hashid there instead, so it is the 'duplicate' reason.
  def reasons
    @reasons ||= if already_applied?
                   [ 'duplicate' ]
    else
                   @apply.failure_info[:detail].to_s.split(',').map(&:strip).compact_blank.uniq
    end
  end

  def already_applied?
    @apply.failure_code == 'already_applied'
  end

  def reason_text(reason)
    I18n.t("apply.review.reason.#{reason}")
  end

  def foreign_origin?
    reasons.include?('foreign_origin')
  end

  # ApproveReview refuses an already_applied review without confirm_duplicate, so the checkbox must render for it.
  def duplicate?
    already_applied? || reasons.include?('duplicate')
  end

  def form_host
    @form_host ||= begin
      URI.parse(@apply.form_url.to_s).host
    rescue URI::InvalidURIError
      nil
    end
  end

  # Hidden fields are never shown; a field nobody answered and that is optional has nothing to review.
  def rows
    @rows ||= @apply.field_list.select { |field| field.fillable? && (field.required || answer(field)) }
  end

  def answer(field)
    @apply.answer_for(field.id)
  end

  def value(field)
    answer(field)&.dig('value')
  end

  def consent?(field)
    CONSENT_SEMANTICS.include?(field.semantic)
  end

  def input_name(field)
    "answers[#{field.id}]"
  end

  def input_id(field)
    "#{form_id}_#{rows.index(field)}"
  end

  def option_labels(field)
    return unless field.option_kind? && field.options.is_a?(Array)

    field.options.map { |option| option['label'].to_s }
  end

  def input_kind(field)
    return :file if field.file?
    return :textarea if field.textarea?
    return :checkbox if field.kind == 'checkbox'
    return :select if option_labels(field)

    :text
  end

  def multiple?(field)
    field.multi_valued?
  end

  ISO_DATE = /\A\d{4}-\d{2}-\d{2}\z/

  # The typed input only when the stored answer is a valid value for it: a date input shows (and posts) "" for
  # "June 2025", which would erase the answer as a user edit, so such a value stays a text input.
  def text_type(field)
    return 'text' unless TEXT_KINDS.include?(field.kind) && field.kind != 'range'
    return 'text' if field.kind == 'date' && value(field).present? && !ISO_DATE.match?(value(field).to_s)

    field.kind
  end

  # CoerceValue accepts fractions (3.5); the default step=1 would make the browser refuse to submit them.
  def number_step(field)
    'any' if text_type(field) == 'number'
  end

  def checked?(field)
    ActiveModel::Type::Boolean.new.cast(value(field)) || false
  end

  def selected(field)
    multiple?(field) ? Array(value(field)) : value(field).to_s
  end

  def select_options(field)
    labels = option_labels(field)
    labels |= Array(selected(field)).compact_blank
    helpers.options_for_select(labels, selected(field))
  end

  def cv_filename
    @apply.cv.attached? ? @apply.cv.filename.to_s : I18n.t('apply.review.cv_default')
  end

  def source_chip(field)
    answer = answer(field)
    return unless answer

    source = answer['source'].to_s
    label = I18n.t("apply.review.source.#{source}", default: source)
    return label unless source == 'ai' && answer['confidence']

    "#{label} - #{I18n.t('apply.review.ai_confidence', percent: (answer['confidence'].to_f * 100).round)}"
  end

  def description(field)
    field.description.to_s.squish.presence
  end

  def cancel_path
    helpers.cancel_apply_path(@apply)
  end
end
