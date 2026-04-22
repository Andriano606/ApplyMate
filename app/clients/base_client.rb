# frozen_string_literal: true

class BaseClient
  def fetch_body(url)
    raise NotImplementedError
  end
end
