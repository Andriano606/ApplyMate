def within_preset(name, &block)
  saved_filter = SavedFilter.find_by!(name:)
  within('[data-test-id="saved-filter-pills"]') do
    within(%([data-model-id="#{saved_filter.id}"]), &block)
  end
end

# The preset pill carries its name and how many vacancies it matches now.
Then('the preset {string} shows {string}') do |name, text|
  within_preset(name) { expect(page).to have_text(text) }
end
