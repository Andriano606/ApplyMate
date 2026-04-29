# frozen_string_literal: true

class BaseClient
  def fetch_response(url)
    raise NotImplementedError
  end
end
