# frozen_string_literal: true

class BaseScraper
  def fetch_listing
    raise NotImplementedError
  end

  def fetch_details(url)
    raise NotImplementedError
  end
end
