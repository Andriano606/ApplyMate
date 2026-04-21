# frozen_string_literal: true

class ApplyMate::Component::Header < ApplyMate::Component::Base
  renders_one :buttons

  attr_reader :title, :back_link, :back_text

  def initialize(title:, back_link: nil, back_text: nil)
    @title = title
    @back_link = back_link
    @back_text = back_text
  end

  def show_back_link?
    back_link.present?
  end

  def back_link_text
    back_text || I18n.t('admin.common.back')
  end
end
