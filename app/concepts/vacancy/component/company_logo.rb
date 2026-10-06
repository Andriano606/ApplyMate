# frozen_string_literal: true

# Company logo of a vacancy, falling back to the company's initial when there is no (loadable) icon.
# Used by the search card (Vacancy::Component::Card) and the vacancy page summary (Vacancy::Component::Show).
class Vacancy::Component::CompanyLogo < ApplyMate::Component::Base
  SIZES = {
    md: 'w-10 h-10 rounded-lg text-sm',
    lg: 'w-12.5 h-12.5 rounded-xl text-base'
  }.freeze

  def initialize(vacancy:, size: :md)
    raise ArgumentError, "Unknown size: #{size}. Valid sizes: #{SIZES.keys.join(', ')}" unless SIZES.key?(size)

    @vacancy = vacancy
    @size    = size
  end

  private

  def size_classes
    SIZES[@size]
  end

  # data-turbo-permanent carries an element with the same id across Turbo visits, so a non-default
  # size gets its own id — otherwise the card's small logo would be kept on the vacancy page.
  def element_id
    @size == :md ? "company_logo_#{@vacancy.hashid}" : "company_logo_#{@size}_#{@vacancy.hashid}"
  end

  def valid_icon_url?
    return false if @vacancy.company_icon_url.blank?

    uri = URI.parse(@vacancy.company_icon_url)
    uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)
  rescue URI::InvalidURIError
    false
  end

  def company_initial
    @vacancy.company_name.to_s.first.to_s.upcase
  end
end
