# frozen_string_literal: true

class ApplyMate::Endpoint::Base
  # These match in order, so if we need more specific, they need to be higher in the list
  CASES = {
    success: Dry::Matcher::Case.new(
      match: ->(result) { result.success? },
      resolve: ->(result) { result },
    ),
    invalid: Dry::Matcher::Case.new(
      match: lambda do |result|
        result.failure?
      end,
      resolve: lambda { |result|
        result
      },
    )
  }.freeze

  def call(result, &)
    Matcher::MatcherWithDefaults.new(CASES, &@default_handling).call(result, &)
  end

  protected

  def find_model_name(component)
    model_name = concept_underscored_class_name(component)
    @controller.action_name == 'index' ? model_name.pluralize : model_name
  end
end
