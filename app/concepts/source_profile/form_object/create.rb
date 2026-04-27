# frozen_string_literal: true

class SourceProfile::FormObject::Create < ApplyMate::FormObject::Base
  property :source_id
  property :name
  property :auth_method
  property :session_id

  validates :source_id, :name, :auth_method, presence: true
  validates :session_id, presence: true, if: :session_id_auth?

  private

  def session_id_auth?
    auth_method == 'session_id'
  end
end
