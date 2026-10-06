# frozen_string_literal: true

# Placeholder inside a lazy turbo-frame of the vacancy page; replaced as soon as the frame's src loads.
class Vacancy::Component::SectionSkeleton < ApplyMate::Component::Base
  def initialize(rows: 2)
    @rows = rows
  end
end
