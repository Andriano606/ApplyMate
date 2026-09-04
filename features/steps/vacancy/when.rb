VACANCY_CARD = '[data-test-id="vacancy-card"]'.freeze

def find_vacancy_card(title)
  find(VACANCY_CARD, text: title, match: :first)
end

When('I click {string} on the vacancy card {string}') do |button, title|
  within(find_vacancy_card(title)) do
    # the restore button only becomes visible on hover, so click it through JS
    find(:button, button, visible: :all).execute_script('this.click()')
  end
end

When('I hover over the vacancy card {string}') do |title|
  find_vacancy_card(title).hover
end
