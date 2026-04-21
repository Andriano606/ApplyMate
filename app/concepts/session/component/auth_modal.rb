# frozen_string_literal: true

class Session::Component::AuthModal < ApplyMate::Component::Base
  def initialize(**)
  end

  def modal_id
    'session_modal'
  end

  def modal_title
    I18n.t('session.auth_modal.title')
  end
end
