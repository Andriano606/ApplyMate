# frozen_string_literal: true

# The list of other people's reviews; the viewer's own review is pinned in its
# own panel above and is not part of the list.
Then('I see {int} feedback card(s)') do |count|
  expect(page).to have_css('section:not([data-test-id="own-feedback"]) [data-test-id="feedback-card"]', count:)
end

Then('my own feedback shows {string}') do |text|
  expect(page).to have_css('[data-test-id="own-feedback"]', text:)
end

Then('the thread under the review by {string} shows {string}') do |author, text|
  within(feedback_card_by(author)) do
    expect(page).to have_css('[data-test-id="feedback-thread"]', text:)
  end
end

Then('there is no reply form on the page') do
  expect(page).to have_css('[data-test-id="feedback-thread"]')
  expect(page).to have_no_css('[data-test-id="feedback-reply-form"]')
end

Then('the navbar shows the unread feedback reply badge') do
  expect(page).to have_css('[data-test-id="navbar-unread-badge"]')
end

Then('the navbar shows no unread feedback reply badge') do
  expect(page).to have_no_css('[data-test-id="navbar-unread-badge"]', visible: :all)
end

Then('the reply {string} is marked as new') do |text|
  reply = find('[data-test-id="feedback-reply"]', text:)
  expect(reply).to have_css('[data-test-id="feedback-reply-new"]')
end

Then('the reply {string} is not marked as new') do |text|
  expect(page).to have_css('[data-test-id="feedback-reply"]', text:)
  expect(page).to have_no_css('[data-test-id="feedback-reply-new"]')
end

Then('the navbar unread badge shows {string}') do |count|
  expect(page).to have_css('[data-test-id="navbar-unread-badge"]', text: count)
end

Then('the unread replies filter is shown') do
  expect(page).to have_css('[data-test-id="feedback-filter-unread"]')
end

Then('I see the call to write a feedback') do
  expect(page).to have_css('[data-test-id="own-feedback"]', text: I18n.t('feedback.index.cta_title'))
end

Then('the feedback {string} no longer exists') do |text|
  wait_for { Feedback.exists?(body: text) }.to be(false)
end
