# frozen_string_literal: true

class Vacancy::Component::Card < ApplyMate::Component::Base
  def initialize(vacancy:, apply: nil)
    @vacancy = vacancy
    @apply = apply
  end

  private

  def description
    sanitized = ActionController::Base.helpers.strip_tags(@vacancy.description)
    truncate(sanitized, length: 300, separator: ' ')
  end

  def valid_icon_url?
    return false unless @vacancy.company_icon_url.present?

    uri = URI.parse(@vacancy.company_icon_url)
    uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)
  rescue URI::InvalidURIError
    false
  end

  def company_initial
    @vacancy.company_name.to_s.first.upcase
  end
end
