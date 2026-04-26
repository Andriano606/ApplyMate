# frozen_string_literal: true

class Apply::Component::Index < ApplyMate::Component::Base
  def initialize(applies:, **)
    @applies = applies
  end

  private

  def header_opts
    { title: I18n.t('apply.index.title') }
  end
end
