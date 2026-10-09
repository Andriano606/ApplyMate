# frozen_string_literal: true

# One apply on the vacancy page. id "apply_<hashid>" is the anchor AppliesController#show, the status badge
# and the "My applies" table link to; data-model-id lets the destroy turbo stream (remove_by_id) drop it.
class Apply::Component::VacancyApplyCard < ApplyMate::Component::Base
  LAZY = :lazy

  # scroll-mt clears the sticky navbar when the page is opened at #apply_<hashid>; the ring marks that card
  # (data-highlighted is set by the anchor-scroll controller: CSS :target never matches a lazily loaded card).
  CARD_CLASSES = 'scroll-mt-24 rounded-xl border border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-800 ' \
                 'data-highlighted:ring-2 data-highlighted:ring-indigo-500 dark:data-highlighted:ring-indigo-400'
  META_CHIP_CLASSES = 'inline-flex max-w-full items-center rounded-full bg-gray-100 px-2.5 py-1 text-xs ' \
                      'text-gray-700 dark:bg-gray-700 dark:text-gray-300'
  CV_ROW_CLASSES = 'flex flex-wrap items-center justify-between gap-3 rounded-xl border border-gray-200 ' \
                   'px-4 py-3 dark:border-gray-700 sm:px-6'

  def self.anchor_id(apply)
    "apply_#{apply.hashid}"
  end

  # Broadcasts (ApplicationController.renderer has no current_user) pass user: explicitly.
  def initialize(apply:, open: false, user: LAZY)
    @apply       = apply
    @vacancy     = apply.vacancy
    @open        = open
    @user_preset = user
  end

  def before_render
    @user = @user_preset == LAZY ? current_user : @user_preset
  end

  private

  def anchor_id
    self.class.anchor_id(@apply)
  end

  def cv_anchor
    "##{VacancyCv::TurboHandler::CvReady.frame_id(@apply)}"
  end

  def screenshot_path
    helpers.artifact_path('apply', @apply, 'screenshot')
  end

  def cv_download_path
    helpers.artifact_path('apply', @apply, 'cv', disposition: 'attachment')
  end

  def meta_items
    [
      { label: I18n.t('apply.card.meta.user_profile'), value: @apply.user_profile.name, icon: :user },
      { label: I18n.t('apply.card.meta.ai_integration'), value: @apply.ai_integration.label, icon: :sparkles },
      { label: I18n.t('apply.card.meta.source_profile'), value: @apply.source_profile.name, icon: :key },
      { label: I18n.t('apply.card.meta.apply_type'), value: apply_type_label, icon: :globe_alt }
    ]
  end

  def apply_type_label
    return I18n.t('apply.apply_type.unknown') if @apply.apply_type.blank? || @apply.unknown?

    I18n.t("apply.apply_type.#{@apply.apply_type}")
  end
end
