# frozen_string_literal: true

class Apply::Component::InfoCard < ApplyMate::Component::Base
  def initialize(apply:)
    @apply   = apply
    @vacancy = apply.vacancy
  end

  private

  def apply_type_label
    return I18n.t('apply.apply_type.unknown') if @apply.apply_type.blank? || @apply.unknown?

    I18n.t("apply.apply_type.#{@apply.apply_type}")
  end
end
