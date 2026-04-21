# frozen_string_literal: true

require 'dry-matcher'

module Matcher
  class EvaluatorWithDefaults < Dry::Matcher::Evaluator
    def initialize(result, cases, &default_block)
      @default_block = default_block
      super result, cases
    end

    def call
      yield self if ::Kernel.block_given?
      @default_block&.call(self)
      ensure_exhaustive_match

      @output
    end
  end
end
