# frozen_string_literal: true

# Presses one key on a target inside Engine::GuardAction, then settles (:key). Only KEYS (the Navigator's closed
# action vocabulary, design §6.2): a recipe never types text.
class Apply::Recipe::Op::Press < Apply::Recipe::Op::Targeted
  KEYS = %w[ArrowDown Enter Escape Tab].freeze

  def self.attributes
    %w[target key]
  end

  def self.from_h(attrs)
    new(target: target_from(attrs), key: attrs.fetch('key'))
  end

  attr_reader :key

  def initialize(target:, key:)
    super(target:)
    raise ArgumentError, "recipe op press: key #{key.inspect} is not one of #{KEYS.join(', ')}" unless KEYS.include?(key)

    @key = key
  end

  def perform!(ctx)
    Apply::Operation::Engine::GuardAction.call(ctx:, action: -> { ctx.session.press(target, key) })
    ctx.session.settle(settle_kind)
  end

  def to_h
    super.merge('key' => key)
  end

  def settle_kind
    :key
  end

  def opens_tab?
    true
  end
end
