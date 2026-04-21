# frozen_string_literal: true

class ApplyMate::Component::Avatar < ApplyMate::Component::Base
  SIZES = {
    sm: { wrapper: 'w-8 h-8',   text: 'text-xs' },
    md: { wrapper: 'w-10 h-10', text: 'text-sm' },
    lg: { wrapper: 'w-11 h-11', text: 'text-sm' }
  }.freeze

  def initialize(user:, size: :md)
    @user = user
    @size = size.to_sym
  end

  private

  attr_reader :user, :size

  def avatar_attached?
    user.avatar.attached?
  end

  def initials
    user.name.to_s.split.map { |w| w[0]&.upcase }.first(2).join.presence || '?'
  end

  def wrapper_classes
    "#{SIZES[size][:wrapper]} rounded-full flex-none"
  end

  def text_classes
    "#{SIZES[size][:text]} font-semibold"
  end
end
