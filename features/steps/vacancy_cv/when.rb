# A CV card on the vacancy page: "the last VacancyCv" (generated manually) or "the CV of the last Apply".
def find_cv_card(owner)
  record = owner == 'the CV of the last Apply' ? Apply.last : VacancyCv.last
  find("##{VacancyCv::TurboHandler::CvReady.frame_id(record)}")
end

# Lets queued hashchange / turbo:frame-load handlers and requestAnimationFrame callbacks (anchor-scroll) run,
# so an accordion they open is not toggled or asserted on before they get to it.
def settle_page
  page.evaluate_async_script('const done = arguments[0]; requestAnimationFrame(() => setTimeout(done, 50))')
end

When(/^I (?:expand|collapse) (the last VacancyCv|the CV of the last Apply)$/) do |owner|
  settle_page
  find_cv_card(owner).find('summary', match: :first).click
end

When(/^I click on "([^"]*)" in (the last VacancyCv|the CV of the last Apply)$/) do |text, owner|
  card = find_cv_card(owner)
  card.find(:link_or_button, text).click
  # The tab frame has loaded once the default (preview) tab is gone.
  expect(card).to have_no_css('iframe') if text == I18n.t('vacancy_cv.tab_prompt')
end
