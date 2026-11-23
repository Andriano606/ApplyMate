# frozen_string_literal: true


When('I click on {string}') do |text|
  element = find(:link_or_button, text, visible: :all, match: :first, wait: 5)
  # Use JS click to bypass overlay issues with modals and hidden elements (e.g. dropdown menus)
  element.execute_script('this.click()')
end

# Dynamic page visit step with support for:
# - Home page: "home page"
# - Dashboard: "admin dashboard"
# - Index pages: "admin Printer index page"
# - New pages: "new admin printer page"
# - Edit/Show pages: "edit Company page" / "show Sale::Invoice page"
# - Query parameters: "edit Company page with sub_section users"
#
# Examples:
#   When I open the home page
#   When I visit the admin dashboard
#   When I visit the admin Printer index page
#   When I visit the new admin printer page
When(/^.* (?:visit|visits|open|try to visit) the (.*?)(?: with (\w+) (.+))?$/) do |page_name, param_name, param_value|
  # Special case for home page
  if page_name == 'home page'
    visit root_path
    next
  end

  # Special case for dashboard
  if page_name == 'admin dashboard'
    visit admin_root_path
    next
  end

  # Remove "page" suffix if present
  page_name = page_name.gsub(/ page$/, '')

  namespace = if page_name.starts_with?('admin')
                page_name = page_name.gsub(/^admin /, '')
                [ :admin ]
  else
                []
  end

  path_parts = if page_name.ends_with?(' index')
                 [ *namespace, page_name.gsub(/ index$/, '').gsub(' ', '::').constantize ]
  elsif page_name.starts_with?('new ')
                 [ :new,
                   *namespace,
                   *page_name.gsub(/^new /, '').split(' ').map do |s|
                     s.underscore.tr('/', '_').to_sym
                   end ]
  elsif page_name.match?(/^(edit|show) [A-Z]/)
                 constant = page_name.gsub(/^(edit|show) /, '').gsub(' ', '::').constantize
                 instance_var_name = "@#{constant.name.underscore.tr('/', '_')}"
                 model = instance_variable_get(instance_var_name) || constant.last
                 action = page_name.start_with?('edit') ? :edit : nil
                 [ action, *namespace, model ].compact
  end

  args = {}
  args[:current_company_hashid] = @company.hashid if @company && path_parts != %i[new company]

  # Add query parameter if provided
  args[param_name.to_sym] = param_value if param_name.present?

  visit polymorphic_path(path_parts, args)
end

When('I fill in {string} with {string}') do |field, value|
  input = find_field(field)

  # For inputs that trigger turbo-form#update on keyup, type character by character
  # and wait for the turbo response to settle after each keystroke.
  if input['data-action']&.include?('turbo-form#update')
    # Clear existing value first
    input.set('')
    # Wait for turbo to process the cleared value
    find_field(field, wait: 5) { |el| el.value == '' }

    accumulated = ''
    value.each_char do |char|
      input = find_field(field)
      input.send_keys(char)
      accumulated += char
      # Wait for turbo to replace the DOM and the new input to have the expected value
      expected = accumulated
      find_field(field, wait: 5) { |el| el.value == expected }
    end
  else
    fill_in field, with: value
  end
end

When('I check {string}') do |label|
  check label
end

When('I set field {string} to {string}') do |name, value|
  find("input[name='#{name}']").set(value)
end

When('I choose {string}') do |label|
  choose(label, exact: false, allow_label_click: true, disabled: false, match: :first)
end

When('I select {string} from {string}') do |value, label|
  select value, from: label
end

# Attach a file from spec/fixtures/files/ to a file input found by name attribute.
# Works with hidden file inputs (e.g. file-drop component).
# Examples:
#   When I attach the file "test_model.stl" to "print_order[model_files][]"
When('I attach the file {string} to {string}') do |filename, field_name|
  path = Rails.root.join('spec/fixtures/files', filename).to_s
  attach_file(field_name, path, make_visible: true)
end

# Click a color swatch radio button identified by its hex code.
# The swatch input is sr-only; JS click is used to trigger the change event.
# Examples:
#   When I select the color "#ff0000"
When('I select the color {string}') do |hex_code|
  color = MaterialColor.find_by!(hex_code: hex_code.downcase)
  find("input[type='radio'][name*='material_color_ids'][value='#{color.id}']", visible: :all)
    .execute_script('this.click()')
end

# Click edit or delete button in a table row containing specific text
# Examples:
#   When I click the edit button for "PLA" in the table
#   When I click the delete button for "Prusa MK4" in the table
When(/^I click the (edit|delete) button for "([^"]*)" in the table$/) do |action, text|
  row = find('table tbody tr', text: /\A#{Regexp.escape(text)}\b/, match: :first)
  if action == 'delete'
    accept_confirm do
      row.find('a[data-turbo-method="delete"]').click
    end
  else
    row.find("a[data-test-id=\"edit-button\"]").click
  end
end
