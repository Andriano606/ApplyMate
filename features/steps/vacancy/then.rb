VACANCY_DESCRIPTION = '[data-test-id="vacancy-description"]'.freeze

Then('the vacancy description renders {int} bullet points') do |count|
  expect(page).to have_css("#{VACANCY_DESCRIPTION} ul li", count: count)
end

Then('the vacancy description renders {string} in bold') do |text|
  expect(page).to have_css("#{VACANCY_DESCRIPTION} strong", text: text)
end

Then('the vacancy description contains no {string} element') do |tag|
  expect(page).to have_no_css("#{VACANCY_DESCRIPTION} #{tag}", visible: :all)
end
