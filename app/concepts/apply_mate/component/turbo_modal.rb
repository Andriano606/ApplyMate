# frozen_string_literal: true

class ApplyMate::Component::TurboModal < ApplyMate::Component::Base
  SIZES = {
    sm: 'max-w-sm',
    md: 'max-w-md',
    lg: 'max-w-lg',
    xl: 'max-w-xl',
    full: 'max-w-full mx-4'
  }.freeze

  renders_one :body
  renders_one :footer

  attr_reader :modal_id, :title, :size

  def initialize(modal_id:, title: nil, size: :md)
    @modal_id = modal_id
    @title = title
    @size = size
  end

  def size_class
    SIZES.fetch(size, SIZES[:md])
  end
end
