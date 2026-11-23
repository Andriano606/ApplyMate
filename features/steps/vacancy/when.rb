When('I click on {string} in the vacancy page navigation') do |text|
  within("nav[aria-label='#{I18n.t('vacancy.show.nav.title')}']") { click_link(text) }
end
