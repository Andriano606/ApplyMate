# frozen_string_literal: true

class Vacancy::Component::SearchBar < ApplyMate::Component::Base
  def initialize(query: nil, exclude: nil, count: nil)
    @query = query
    @exclude = exclude
    @count = count
  end
end
