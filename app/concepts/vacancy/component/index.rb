# frozen_string_literal: true

class Vacancy::Component::Index < ApplyMate::Component::Base
  def initialize(vacancies:, applies_by_vacancy: {}, include_tags: nil, include_ops: nil, exclude_tags: nil, **)
    @vacancies = vacancies
    @applies_by_vacancy = applies_by_vacancy
    @include_tags = include_tags
    @include_ops = include_ops
    @exclude_tags = exclude_tags
  end
end
