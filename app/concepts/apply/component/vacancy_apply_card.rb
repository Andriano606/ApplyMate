# frozen_string_literal: true

# One apply on the vacancy page. id "apply_<hashid>" is the anchor AppliesController#show, the status badge
# and the "My applies" table link to; data-model-id lets the destroy turbo stream (remove_by_id) drop it.
class Apply::Component::VacancyApplyCard < ApplyMate::Component::Base
  # scroll-mt clears the sticky navbar when the page is opened at #apply_<hashid>; the ring marks that card
  # (data-highlighted is set by the anchor-scroll controller: CSS :target never matches a lazily loaded card).
  CARD_CLASSES = 'scroll-mt-24 rounded-xl border border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-800 ' \
                 'data-highlighted:ring-2 data-highlighted:ring-indigo-500 dark:data-highlighted:ring-indigo-400'
  META_CHIP_CLASSES = 'inline-flex max-w-full items-center rounded-full bg-gray-100 px-2.5 py-1 text-xs ' \
                      'text-gray-700 dark:bg-gray-700 dark:text-gray-300'
  CV_ROW_CLASSES = 'flex flex-wrap items-center justify-between gap-3 rounded-xl border border-gray-200 ' \
                   'px-4 py-3 dark:border-gray-700 sm:px-6'
  ERROR_BOX_CLASSES = 'mx-4 mt-4 rounded-lg border border-red-200 bg-red-50 p-3 sm:mx-5 ' \
                      'dark:border-red-900/50 dark:bg-red-900/20'

  def self.anchor_id(apply)
    "apply_#{apply.hashid}"
  end

  def initialize(apply:, open: false)
    @apply   = apply
    @vacancy = apply.vacancy
    @open    = open
  end

  private

  def anchor_id
    self.class.anchor_id(@apply)
  end

  def cv_anchor
    "##{VacancyCv::TurboHandler::CvReady.frame_id(@apply)}"
  end

  def screenshot_path
    helpers.rails_blob_path(@apply.screenshot, disposition: 'inline')
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

  def new_apply_path
    helpers.new_apply_path(vacancy_id: @vacancy.hashid)
  end
end
