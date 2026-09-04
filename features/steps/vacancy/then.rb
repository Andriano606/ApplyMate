Then('the vacancy card {string} is hidden') do |title|
  expect(page).to have_css("#{VACANCY_CARD}[data-hidden='true']", text: title)
end

Then('the vacancy card {string} is not hidden') do |title|
  expect(page).to have_css("#{VACANCY_CARD}:not([data-hidden])", text: title)
end
