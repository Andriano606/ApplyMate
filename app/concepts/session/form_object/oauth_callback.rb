# frozen_string_literal: true

class Session::FormObject::OauthCallback < ApplyMate::FormObject::Base
  property :name
  property :email
  property :image
  property :avatar_url
  property :provider
  property :uid

  def image=(value)
    @image = value
    @avatar_url = value
  end

  validates :name, :email, presence: true
end
