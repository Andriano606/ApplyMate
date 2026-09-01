def within_preset(name, &block)
  saved_filter = SavedFilter.find_by!(name:)
  within('[data-test-id="saved-filter-pills"]') do
    within(%([data-model-id="#{saved_filter.id}"]), &block)
  end
end

# The preset pill carries a plain vacancy count plus optional "+appeared" and
# "−disappeared" badges.
Then('the preset {string} shows {string}') do |name, badge|
  within_preset(name) { expect(page).to have_text(badge) }
end

Then('the preset {string} shows no deltas') do |name|
  within_preset(name) { expect(page).to have_no_text(/[+−]\d+/) }
end
