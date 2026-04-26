# frozen_string_literal: true

class User < ApplicationRecord
  has_many :user_profiles, dependent: :destroy
  has_many :ai_integrations, dependent: :destroy
  has_many :applies, dependent: :destroy

  belongs_to :default_profile, class_name: 'UserProfile', optional: true
  belongs_to :default_ai_integration, class_name: 'AiIntegration', optional: true

  has_one_attached :avatar do |attachable|
    attachable.variant :thumb, resize_to_fill: [ 64, 64 ], format: :webp
  end
  validates :email, presence: true
  validates :name, presence: true
  validates :provider, presence: true
  validates :uid, presence: true, uniqueness: { scope: :provider }

  def admin?
    admin
  end

  def admin!
    update!(admin: true)
  end

  def download_avatar!
    return if avatar_url.blank?

    uri = URI.parse(avatar_url)
    response = Net::HTTP.get_response(uri)
    return unless response.is_a?(Net::HTTPSuccess)

    content_type = response['content-type'] || 'image/jpeg'
    extension = Rack::Mime::MIME_TYPES.invert[content_type] || '.jpg'

    avatar.attach(
      io: StringIO.new(response.body),
      filename: "avatar_#{id}#{extension}",
      content_type: content_type
    )
  rescue URI::InvalidURIError, SocketError, Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError => e
    Rails.logger.warn("Failed to download avatar for user #{id}: #{e.message}")
  end
end
