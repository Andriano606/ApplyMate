# frozen_string_literal: true

# The filter pills of the feedback page carry data-test-id="feedback-filter-<sentiment|all>".
When('I filter the feedback by {word}') do |sentiment|
  find("[data-test-id='feedback-filter-#{sentiment}']").click
end

def feedback_card_by(author)
  find('[data-test-id="feedback-card"]', text: author, match: :first)
end

# The reply form is a collapsed <details>; its <summary> is neither link nor button,
# so the generic `I click on` cannot reach it.
When('I start a reply under the review by {string}') do |author|
  within(feedback_card_by(author)) { find('[data-test-id="feedback-reply-form"] summary').click }
end

When('I fill in the reply with {string}') do |text|
  find('[data-test-id="feedback-reply-form"][open] textarea').set(text)
end

# The rating is 10 radio chips: the input is sr-only, the visible <label> carries the number.
When('I pick the rating {int}') do |rating|
  find('[data-test-id="feedback-rating-picker"] label', text: /\A#{rating}\z/).click
end

# Every review shows its own reply form to an admin, so the generic `I click on
# "Надіслати"` would press the first form's button; submit the open one.
When('I send the reply') do
  within('[data-test-id="feedback-reply-form"][open]') do
    find(:button, I18n.t('feedback_reply.form.submit'), visible: :all).execute_script('this.click()')
  end
end

# The trash button on a card asks for a native confirmation (data-turbo-confirm).
When('I delete my feedback and confirm') do
  accept_confirm do
    find('[data-test-id="own-feedback"] [data-test-id="feedback-delete"]').click
  end
end
