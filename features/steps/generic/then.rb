# frozen_string_literal: true

# Check for text on page or notice in flash message
# Supports positive and negative assertions.
# Examples:
#   Then I see text "Hello"
#   Then I do not see text "Hello"
#   Then I see notice "Material created"
Then(/^I (do not see|see) (text|notice|alert) "([^"]*)"$/) do |negation, type, text|
  positive = negation == 'see'
  if type == 'notice' || type == 'alert'
    if positive
      expect(page).to have_css('[data-flash-target="message"]', text: text)
    else
      expect(page).to have_no_css('[data-flash-target="message"]', text: text)
    end
  else
    if positive
      expect(page).to have_content(text)
    else
      expect(page).to have_no_content(text)
    end
  end
end

Then('I see button {string}') do |text|
  expect(page).to have_button(text)
end

Then('I see link {string}') do |text|
  expect(page).to have_link(text)
end

# Check if modal is visible or not
# Examples:
#   Then I should see the modal
#   Then I should not see the modal
Then(/^I (should|should not) see the modal$/) do |visibility|
  if visibility == 'should'
    expect(page).to have_css('[data-controller="turbo-modal"]', wait: 5)
  else
    expect(page).to have_no_css('[data-controller="turbo-modal"]', wait: 5)
  end
end

# Check for error message under a specific field by input name attribute
# Examples:
#   Then I see error "не може бути пустим" under "printer[name]"
#   Then I see error "is invalid" under "user[email]"
Then('I see error {string} under {string}') do |error_message, field_name|
  # Find the wrapper containing the input with matching name attribute
  wrapper = find(:xpath, "//*[@name='#{field_name}']/ancestor::div[contains(@class, 'mb-')]")
  expect(wrapper).to have_css('.text-red-600', text: error_message)
end

# Check form field values by name attribute
# Examples:
#   Then I should see the form with values:
#     | material[name] | PLA |
#     | printer[print_width] | 250 |
Then('I should see the form with values:') do |table|
  table.raw.each do |field_name, expected_value|
    field = find(:xpath, "//*[@name='#{field_name}']")
    actual_value = field.value
    expect(actual_value).to eq(expected_value),
                            "Field '#{field_name}': expected '#{expected_value}', got '#{actual_value}'"
  end
end

# Check that a record has specific attributes (with wait_for for async operations).
# Table format: two columns — attribute name and expected value.
#
# Find the last record:
#   Then the last PrintOrder record should have:
#     | status | open |
#
# Find by attribute (id, hashid, name, etc.):
#   Then the PrintOrder with hashid "abc123" should have:
#     | status | open |
#
#   Then the Material with name "PLA" should have:
#     | category | simple |
Then(/^the (?:(last) )?(\w+)(?: with (\w+) "([^"]+)")? record should have:$/) do |last, model_name, find_attr, find_value, table|
  model_class = model_name.constantize
  finder = last ? -> { model_class.last } : -> { model_class.find_by(find_attr => find_value) }
  table.rows_hash.each do |attr, value|
    typed_value = convert_table_value(value)
    wait_for { finder.call&.public_send(attr) }.to eq(typed_value)
  end
end

# Check that database records exist with specific attributes
# Examples:
#   Then the following Material records should exist:
#     | name |
#     | PLA+ |
#     | ABS  |
#
#   Then the following Printer records should exist:
#     | name       | print_width |
#     | Prusa MK4  | 250         |
Then('the following {word} records should exist:') do |model_name, table|
  model_class = model_name.constantize
  table.hashes.each do |expected_attrs|
    typed_attrs = expected_attrs.transform_values do |v|
      case v
      when /\A\d+\z/ then v.to_i
      when /\A\d+\.\d+\z/ then v.to_f
      when 'true' then true
      when 'false' then false
      else v
      end
    end
    record = model_class.find_by(typed_attrs)
    expect(record).not_to be_nil,
                          "Expected #{model_name} with #{typed_attrs.inspect} to exist, but it was not found"
  end
end

# Check table content - headers and rows in exact order
# Examples:
#   Then I should see the table:
#     | Назва | Кількість принтерів |
#     | PLA   | 0                   |
#     | ABS   | 0                   |
Then('I should see the table:') do |expected_table|
  rows = expected_table.raw
  headers = rows.first
  expected_data_rows = rows[1..]

  # Wait for expected first row to appear (handles page transitions)
  first_expected_value = expected_data_rows.first&.find(&:present?)
  expect(page).to have_css('table tbody tr', text: first_expected_value, wait: 5) if first_expected_value

  table = find('table')

  # Check headers (in order)
  header_cells = table.all('thead th, thead td').map(&:text)
  headers.each_with_index do |expected_header, index|
    expect(header_cells[index]).to eq(expected_header)
  end

  # Get actual table rows
  actual_rows = table.all('tbody tr').map do |row|
    row.all('td').map(&:text)
  end

  # Check row count matches
  expect(actual_rows.size).to eq(expected_data_rows.size),
                             "Expected #{expected_data_rows.size} rows, got #{actual_rows.size}"

  # Check each row in order
  expected_data_rows.each_with_index do |expected_row, row_index|
    expected_row.each_with_index do |expected_value, col_index|
      actual_value = actual_rows[row_index][col_index]
      expect(actual_value).to eq(expected_value),
                              "Row #{row_index + 1}, column #{col_index + 1}: expected '#{expected_value}', got '#{actual_value}'"
    end
  end
end
