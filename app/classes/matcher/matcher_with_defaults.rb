# frozen_string_literal: true

require 'dry-matcher'

module Matcher
  class MatcherWithDefaults < Dry::Matcher
    attr_reader :default_block

    def initialize(cases = {}, &default_block)
      @cases = cases
      @default_block = default_block
    end

    def call(result, &)
      EvaluatorWithDefaults.new(result, cases, &default_block).call(&)
    end
  end
end
