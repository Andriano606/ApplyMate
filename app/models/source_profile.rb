# frozen_string_literal: true

class SourceProfile < ApplicationRecord
  belongs_to :user
  belongs_to :source
  has_many :applies, dependent: :destroy

  enum :auth_method, { session_id: 0 }

  encrypts :session_id

  validates :name, :auth_method, presence: true

  def self.default_for(user, source)
    find_by(user: user, source: source, is_default: true)
  end

  def set_as_default!
    SourceProfile.transaction do
      SourceProfile.where(user: user, source: source, is_default: true)
                   .where.not(id: id)
                   .update_all(is_default: false)
      update!(is_default: true)
    end
  end
end
