# frozen_string_literal: true

# The list of everyone's reviews; the viewer's own review is also pinned in its
# own panel above, which is deliberately not counted here.
Then('I see {int} feedback card(s)') do |count|
  expect(page).to have_css('section:not([data-test-id="own-feedback"]) [data-test-id="feedback-card"]', count:)
end

Then('my own feedback shows {string}') do |text|
  expect(page).to have_css('[data-test-id="own-feedback"]', text:)
end
