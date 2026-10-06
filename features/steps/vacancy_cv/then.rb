# Both lazy section frames load in parallel. Turbo marks a frame [complete] in the same tick it fires
# turbo:frame-load, so this also waits for the anchor-scroll reveal of the CV section to have run.
Then('I see the last VacancyCv') do
  expect(page).to have_css('#vacancy-cvs turbo-frame[complete]')
  find_cv_card('the last VacancyCv')
end

Then(/^(the last VacancyCv|the CV of the last Apply) is (expanded|collapsed)$/) do |owner, state|
  card = find_cv_card(owner)
  if state == 'expanded'
    expect(card).to have_css('details[open]')
  else
    settle_page
    expect(card).to have_no_css('details[open]')
  end
end
