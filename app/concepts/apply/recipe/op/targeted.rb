# frozen_string_literal: true

# Abstract: an op that acts on one element. The hash carries 'target' => Target#to_h (frame path + locator
# strategies, never a value the user typed); from_h rebuilds it with Target.from_h. Not in OPS.
class Apply::Recipe::Op::Targeted < Apply::Recipe::Op::Base
  def self.attributes
    %w[target]
  end

  def self.from_h(attrs)
    new(target: target_from(attrs))
  end

  def self.target_from(attrs)
    hash = attrs.fetch('target')
    raise ArgumentError, "recipe op #{op}: target must be a Target hash, got #{hash.class}" unless hash.is_a?(Hash)

    ApplyMate::Client::Browser::Target.from_h(hash)
  end

  attr_reader :target

  def initialize(target:)
    raise ArgumentError, "recipe op #{self.class.op}: target must be a Target" unless target.is_a?(ApplyMate::Client::Browser::Target)

    @target = target
  end

  def to_h
    head('target' => target.to_h)
  end
end
