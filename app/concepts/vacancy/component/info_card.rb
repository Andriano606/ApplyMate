# frozen_string_literal: true

class Vacancy::Component::InfoCard < ApplyMate::Component::Base
  def initialize(vacancy:, apply: nil, expanded: false, expand_url: nil, collapse_url: nil)
    @vacancy = vacancy
    @apply = apply
    @expanded = expanded
    @expand_url = expand_url
    @collapse_url = collapse_url
  end

  private

  def description_preview
    helpers.strip_tags(@vacancy.description.to_s)
  end

  def description_full
    helpers.sanitize(
      @vacancy.description.to_s,
      tags: %w[p br ul ol li strong em b i h1 h2 h3 h4 h5 h6 a],
      attributes: %w[href]
    )
  end

  def apply_type_label
    return unless @apply
    return I18n.t('apply.apply_type.unknown') if @apply.apply_type.blank? || @apply.unknown?

    I18n.t("apply.apply_type.#{@apply.apply_type}")
  end
end
