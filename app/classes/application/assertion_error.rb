# frozen_string_literal: true

# Application::AssertionError is used for assertion-style checks that indicate
# conditions that should never happen in normal operation.
#
# If this error is raised in production, it indicates a bug or missing
# precondition check. The appropriate response is to add preconditions
# earlier in the code flow to ensure this situation cannot occur.
#
# Example usage:
#   raise Application::AssertionError, 'Must have organisation_number' if organisation_number.blank?
#
class Application::AssertionError < StandardError
end
