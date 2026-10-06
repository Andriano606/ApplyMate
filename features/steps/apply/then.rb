# frozen_string_literal: true

def last_apply_card
  find("##{Apply::Component::VacancyApplyCard.anchor_id(Apply.last)}")
end

Then('I am on the vacancy page at the last Apply card') do
  apply = Apply.last
  expect(page).to have_current_path(vacancy_path(apply.vacancy))
  expect(URI.parse(page.current_url).fragment).to eq(Apply::Component::VacancyApplyCard.anchor_id(apply))
  expect(page).to have_css("##{Apply::Component::VacancyApplyCard.anchor_id(apply)}")
end

Then('the last Apply card shows status {string}') do |status|
  expect(last_apply_card).to have_text(status)
end

# Filled form fields are read-only controls labelled through aria-label (Apply::Component::FilledFormPreview).
Then('the last Apply card shows the field {string} filled with {string}') do |label, value|
  expect(last_apply_card.find("[aria-label='#{label}']").value).to eq(value)
end
