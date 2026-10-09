# frozen_string_literal: true

# The code box of a running apply parked in stage 'awaiting_input' (Engine::AwaitInput, design §10.4): the site sent a
# one-time code the user has to type. Posts `code` to Apply::Operation::ProvideInput. Rendered inside StatusUpdate
# broadcasts (the card is replaced on the AwaitInput broadcast), hence the LAZY user.
class Apply::Component::InputRequest < ApplyMate::Component::Base
  LAZY = :lazy
  STAGE = 'awaiting_input'
  EMAIL_CODE = 'email_code'
  MAX_CODE_LENGTH = Apply::Operation::ProvideInput::MAX_CODE_LENGTH
  SECTION_CLASSES = 'rounded-lg border border-amber-300 bg-amber-50 p-3 text-amber-900 ' \
                    'dark:border-amber-800 dark:bg-amber-900/20 dark:text-amber-200 sm:p-4'
  INPUT_CLASSES = 'block w-full rounded-lg border border-gray-300 bg-white px-3 py-2 text-base text-gray-900 ' \
                  'focus:border-indigo-500 focus:ring-indigo-500 dark:border-gray-600 dark:bg-gray-700 ' \
                  'dark:text-gray-100 sm:max-w-xs sm:text-sm'

  def initialize(apply:, user: LAZY)
    @apply       = apply
    @user_preset = user
  end

  def before_render
    @user = @user_preset == LAZY ? current_user : @user_preset
  end

  def render?
    @apply.running? && @apply.stage == STAGE && @apply.input_request.present? && @apply.input_response.blank?
  end

  private

  def request
    @apply.input_request
  end

  def email_code?
    request['kind'] == EMAIL_CODE
  end

  # Literal keys (not "#{scope}.title") so i18n-tasks sees them as used.
  def title
    email_code? ? I18n.t('apply.input_request.email_code.title') : I18n.t('apply.input_request.generic.title')
  end

  def hint
    email_code? ? I18n.t('apply.input_request.email_code.hint') : I18n.t('apply.input_request.generic.hint')
  end

  def expires_at
    time = request['expires_at'].presence && Time.zone.parse(request['expires_at'])
    return unless time

    I18n.t('apply.input_request.expires_at', time: I18n.l(time, format: :short))
  end

  def input_id
    "input_request_code_#{@apply.hashid}"
  end

  def submit_path
    helpers.provide_input_apply_path(@apply, format: :turbo_stream)
  end
end
