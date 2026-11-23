# frozen_string_literal: true

# The filter pills of the feedback page carry data-test-id="feedback-filter-<sentiment|all>".
When('I filter the feedback by {word}') do |sentiment|
  find("[data-test-id='feedback-filter-#{sentiment}']").click
end
