# frozen_string_literal: true

class ApplyMate::Client::Base
  def fetch_body(url)
    raise NotImplementedError
  end
end
